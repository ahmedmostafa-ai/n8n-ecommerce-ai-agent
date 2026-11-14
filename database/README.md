# PostgreSQL Database

This directory contains the database schema and SQL functions used by the E-Commerce AI Agent.

## Database Tables

| Table | Purpose |
|---|---|
| `customers` | Stores customer information and Telegram IDs |
| `products` | Stores product details, prices, and inventory |
| `orders` | Stores confirmed checkout transactions as orders |
| `order_items` | Stores products and quantities associated with orders |
| `checkout_sessions` | Tracks pending, confirmed, cancelled, and expired checkouts |

## Database Functions

### `create_ecommerce_order()`

Creates an order, validates inventory, and updates stock within a PostgreSQL transaction. Uses an idempotency key to prevent duplicate order creation.

### `confirm_ecommerce_checkout()`

Validates checkout ownership and expiration, creates the order, and marks the checkout as confirmed.

### `cancel_ecommerce_checkout()`

Validates checkout ownership and changes an eligible checkout to the cancelled state without creating an order.

## Reliability Features

- Transactional order processing
- Row-level locking during inventory updates
- Idempotency using checkout UUIDs
- Customer ownership validation
- Product availability and quantity validation
- Checkout expiration and cancellation

## SQL Files

Database schema and function definitions will be added separately.
