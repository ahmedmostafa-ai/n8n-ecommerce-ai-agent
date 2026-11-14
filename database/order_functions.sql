-- E-Commerce AI Agent
-- PostgreSQL order processing functions
-- Exported from the application's existing public schema.
-- Run after creating the tables in schema.sql.
-- PostgreSQL functions execute within the calling transaction.

CREATE OR REPLACE FUNCTION public.create_ecommerce_order(p_request_id uuid, p_telegram_id text, p_product_id bigint, p_quantity integer, p_delivery_address text)
 RETURNS TABLE(order_id bigint, order_status character varying, order_total numeric, remaining_stock integer, already_existed boolean)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_customer_id BIGINT;
    v_price NUMERIC;
    v_stock INTEGER;
    v_order_id BIGINT;
    v_status VARCHAR;
    v_total NUMERIC;
BEGIN
    IF p_request_id IS NULL
       OR NULLIF(BTRIM(p_telegram_id), '') IS NULL
       OR p_telegram_id !~ '^[0-9]+$'
       OR p_quantity IS NULL
       OR p_quantity < 1
       OR p_quantity > 20
       OR p_product_id IS NULL
       OR p_product_id <= 0
       OR p_delivery_address IS NULL
       OR LENGTH(BTRIM(p_delivery_address)) < 10
    THEN
        RAISE EXCEPTION 'Invalid order input';
    END IF;

    -- Prevent concurrent processing of the same request.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_request_id::TEXT, 0)
    );

    -- Check whether this request was already processed.
    SELECT o.id, o.status, o.total_amount
    INTO v_order_id, v_status, v_total
    FROM orders o
    WHERE o.request_id = p_request_id;

    IF FOUND THEN

        -- Verify that the existing order matches the request.
        IF NOT EXISTS (
            SELECT 1
            FROM orders o
            JOIN customers c
                ON c.id = o.customer_id
            JOIN order_items oi
                ON oi.order_id = o.id
            WHERE o.id = v_order_id
              AND c.telegram_id = p_telegram_id::BIGINT
              AND oi.product_id = p_product_id
              AND oi.quantity = p_quantity
              AND o.delivery_address = BTRIM(p_delivery_address)
              AND (
                  SELECT COUNT(*)
                  FROM order_items oi2
                  WHERE oi2.order_id = o.id
              ) = 1
        ) THEN
            RAISE EXCEPTION
                'Request ID already belongs to a different order';
        END IF;

        -- Return existing order without changing stock.
        RETURN QUERY
        SELECT v_order_id, v_status, v_total,
               p.stock, TRUE
        FROM products p
        WHERE p.id = p_product_id;

        RETURN;
    END IF;

    -- Find customer.
    SELECT c.id
    INTO v_customer_id
    FROM customers c
    WHERE c.telegram_id = p_telegram_id::BIGINT;

    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'Customer not found';
    END IF;

    -- Lock product and read current price and stock.
    SELECT p.price, p.stock
    INTO v_price, v_stock
    FROM products p
    WHERE p.id = p_product_id
      AND p.is_active = TRUE
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Product unavailable';
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock';
    END IF;

    -- Deduct stock.
    UPDATE products
    SET stock = stock - p_quantity
    WHERE id = p_product_id;

    -- Create order.
    INSERT INTO orders (
        customer_id,
        status,
        total_amount,
        delivery_address,
        request_id
    )
    VALUES (
        v_customer_id,
        'pending',
        v_price * p_quantity,
        BTRIM(p_delivery_address),
        p_request_id
    )
    RETURNING id, status, total_amount
    INTO v_order_id, v_status, v_total;

    -- Create order item.
    INSERT INTO order_items (
        order_id,
        product_id,
        quantity,
        unit_price
    )
    VALUES (
        v_order_id,
        p_product_id,
        p_quantity,
        v_price
    );

    RETURN QUERY
    SELECT v_order_id, v_status, v_total,
           v_stock - p_quantity, FALSE;
END;
$function$;


CREATE OR REPLACE FUNCTION public.confirm_ecommerce_checkout(p_checkout_id uuid, p_telegram_id text)
 RETURNS TABLE(order_id bigint, order_status character varying, order_total numeric, already_existed boolean)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_checkout checkout_sessions%ROWTYPE;
    v_customer_telegram_id BIGINT;
    v_order RECORD;
BEGIN
    IF p_checkout_id IS NULL
       OR p_telegram_id IS NULL
       OR p_telegram_id !~ '^[0-9]+$'
    THEN
        RAISE EXCEPTION 'Invalid confirmation input';
    END IF;

    -- Lock checkout to prevent simultaneous confirmation/cancellation.
    SELECT *
    INTO v_checkout
    FROM checkout_sessions ch
    WHERE ch.id = p_checkout_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Checkout not found';
    END IF;

    -- Verify checkout ownership.
    SELECT c.telegram_id
    INTO v_customer_telegram_id
    FROM customers c
    WHERE c.id = v_checkout.customer_id;

    IF v_customer_telegram_id IS DISTINCT FROM p_telegram_id::BIGINT THEN
        RAISE EXCEPTION 'Checkout does not belong to this customer';
    END IF;

    -- Handle an already confirmed checkout.
    IF v_checkout.status = 'confirmed' THEN
        IF v_checkout.order_id IS NULL THEN
            RAISE EXCEPTION 'Confirmed checkout has no order';
        END IF;

        RETURN QUERY
        SELECT o.id, o.status, o.total_amount, TRUE
        FROM orders o
        WHERE o.id = v_checkout.order_id;

        RETURN;
    END IF;

    -- Reject cancelled or expired checkouts.
    IF v_checkout.status <> 'awaiting_confirmation' THEN
        RAISE EXCEPTION 'Checkout is no longer available';
    END IF;

    IF v_checkout.expires_at <= NOW() THEN
        UPDATE checkout_sessions
        SET status = 'expired'
        WHERE id = p_checkout_id;

        RAISE EXCEPTION 'Checkout has expired';
    END IF;

    -- Create the order using our existing atomic order function.
    SELECT *
    INTO v_order
    FROM create_ecommerce_order(
        v_checkout.id,
        p_telegram_id,
        v_checkout.product_id,
        v_checkout.quantity,
        v_checkout.delivery_address
    );

    -- Mark checkout as confirmed.
    UPDATE checkout_sessions
    SET status = 'confirmed',
        order_id = v_order.order_id
    WHERE id = p_checkout_id;

    RETURN QUERY
    SELECT
        v_order.order_id,
        v_order.order_status,
        v_order.order_total,
        v_order.already_existed;
END;
$function$;


CREATE OR REPLACE FUNCTION public.cancel_ecommerce_checkout(p_checkout_id uuid, p_telegram_id text)
 RETURNS TABLE(checkout_id uuid, checkout_status character varying)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_checkout checkout_sessions%ROWTYPE;
    v_customer_telegram_id BIGINT;
BEGIN
    IF p_checkout_id IS NULL
       OR p_telegram_id IS NULL
       OR p_telegram_id !~ '^[0-9]+$'
    THEN
        RAISE EXCEPTION 'Invalid cancellation input';
    END IF;

    -- Lock checkout to prevent confirmation/cancellation races.
    SELECT *
    INTO v_checkout
    FROM checkout_sessions ch
    WHERE ch.id = p_checkout_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Checkout not found';
    END IF;

    -- Verify the Telegram customer owns this checkout.
    SELECT c.telegram_id
    INTO v_customer_telegram_id
    FROM customers c
    WHERE c.id = v_checkout.customer_id;

    IF v_customer_telegram_id IS DISTINCT FROM p_telegram_id::BIGINT THEN
        RAISE EXCEPTION 'Checkout does not belong to this customer';
    END IF;

    -- An already cancelled checkout stays cancelled.
    IF v_checkout.status = 'cancelled' THEN
        RETURN QUERY
        SELECT v_checkout.id, v_checkout.status;
        RETURN;
    END IF;

    -- Never cancel an already confirmed order.
    IF v_checkout.status = 'confirmed' THEN
        RAISE EXCEPTION 'Checkout already confirmed';
    END IF;

    IF v_checkout.status = 'expired'
       OR v_checkout.expires_at <= NOW()
    THEN
        UPDATE checkout_sessions ch
        SET status = 'expired'
        WHERE ch.id = p_checkout_id
          AND ch.status = 'awaiting_confirmation';

        RETURN QUERY
        SELECT v_checkout.id, 'expired'::VARCHAR;
        RETURN;
    END IF;

    UPDATE checkout_sessions ch
    SET status = 'cancelled'
    WHERE ch.id = p_checkout_id;

    RETURN QUERY
    SELECT v_checkout.id, 'cancelled'::VARCHAR;
END;
$function$;
