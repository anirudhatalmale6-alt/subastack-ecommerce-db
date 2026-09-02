# API examples

These assume the standard PostgREST-style auto-generated REST API over the
`public` schema (tables become `/rest/v1/<table>`, functions become
`/rest/v1/rpc/<function>`), which is what Subastack exposes for a project
like this. If your project's API prefix or auth header differs, only the
URL and headers change — the SQL underneath is identical.

```bash
BASE="https://<project-ref>.subastack.co/rest/v1"
ANON="<anon key>"          # safe in the mobile/web client
TOKEN="<user access token>" # from sign-in
```

---

## Browsing (no sign-in)

```bash
# catalogue, ready to render: price, category, stock, first image
curl "$BASE/v_product_catalog?select=*&order=name" \
  -H "apikey: $ANON"

# one product with its variants and images
curl "$BASE/products?slug=eq.aurora-wireless-headphones&select=*,product_variants(*),product_images(url,alt_text,position)" \
  -H "apikey: $ANON"

# category tree
curl "$BASE/categories?is_active=eq.true&select=id,name,slug,parent_id&order=position" \
  -H "apikey: $ANON"

# is it in stock?
curl "$BASE/v_available_stock?sku=eq.AUR-HP-01-BLK" -H "apikey: $ANON"
```

Draft products are invisible here — `AUR-HP-02` is seeded as `draft`
precisely so you can prove that.

---

## The signed-in shopper

```bash
AUTH=(-H "apikey: $ANON" -H "Authorization: Bearer $TOKEN")

# my profile (returns exactly one row, always mine)
curl "$BASE/customers?select=*" "${AUTH[@]}"

# update it
curl -X PATCH "$BASE/customers?id=eq.$MY_ID" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{"full_name":"Ava Stone","phone":"+1-415-555-0142"}'

# my addresses
curl -X POST "$BASE/addresses" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"'"$MY_ID"'","recipient_name":"Ava Stone",
       "line1":"18 Dolores St","city":"San Francisco","region":"CA",
       "postal_code":"94110","country_code":"US","is_default_shipping":true}'

# my orders, newest first, with their lines
curl "$BASE/orders?select=*,order_items(*),payments(status,amount),shipments(carrier,tracking_number,status)&order=placed_at.desc" \
  "${AUTH[@]}"

# order history summary
curl "$BASE/v_order_summary?order=placed_at.desc" "${AUTH[@]}"
```

Nothing here needs a `customer_id` filter. RLS applies it — asking for
`/orders` returns your orders and no one else's, even without a `where`.

---

## Cart → checkout → cancel

```bash
# add to cart (creates the cart on first call)
curl -X POST "$BASE/rpc/add_to_cart" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{"p_variant_id":"<variant uuid>","p_quantity":2}'

# what is in it
curl "$BASE/cart_items?select=quantity,product_variants(sku,name,price)" "${AUTH[@]}"

# check out -- prices come from the catalogue, totals are computed server side
curl -X POST "$BASE/rpc/checkout_cart" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{"p_cart_id":"<cart uuid>","p_shipping_total":9.00,"p_tax_total":4.50}'

# cancel it while it is still pending
curl -X POST "$BASE/rpc/cancel_order" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{"p_order_id":"<order uuid>","p_reason":"changed my mind"}'
```

`checkout_cart` returns the whole order row, totals already computed, and
the stock is reserved by the time it responds. Cancelling releases the
reservation. Neither is something the app has to remember to do.

---

## Back office (staff token)

A staff token is a normal user token whose `app_metadata.role` is `admin`
or `staff`.

```bash
STAFF=(-H "apikey: $ANON" -H "Authorization: Bearer $STAFF_TOKEN")

# every order awaiting fulfilment
curl "$BASE/orders?payment_status=eq.paid&fulfillment_status=eq.unfulfilled&select=order_number,email,grand_total,placed_at&order=placed_at" \
  "${STAFF[@]}"

# real stock numbers + what needs reordering
curl "$BASE/v_inventory_status?needs_reorder=is.true&select=sku,product_name,quantity_available,reorder_level" \
  "${STAFF[@]}"

# publish a product
curl -X PATCH "$BASE/products?id=eq.<uuid>" "${STAFF[@]}" \
  -H "Content-Type: application/json" -d '{"status":"active"}'

# mark an order shipped -- this deducts the stock
curl -X PATCH "$BASE/orders?id=eq.<uuid>" "${STAFF[@]}" \
  -H "Content-Type: application/json" -d '{"fulfillment_status":"fulfilled"}'
```

---

## Server side only (service key)

The service key bypasses RLS. It belongs on your server, never in the app
bundle.

```bash
SVC=(-H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")

# payment webhook: record a capture. The order's payment_status follows.
curl -X POST "$BASE/payments" "${SVC[@]}" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"<uuid>","provider":"stripe","provider_reference":"pi_3Q…",
       "method":"card","amount":251.50,"currency":"USD","status":"captured",
       "processed_at":"2026-09-02T10:15:00Z"}'

# a refund is a NEGATIVE amount
curl -X POST "$BASE/payments" "${SVC[@]}" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"<uuid>","provider":"stripe","provider_reference":"re_3Q…",
       "amount":-62.88,"currency":"USD","status":"refunded"}'

# receiving stock
curl -X POST "$BASE/rpc/apply_stock_movement" "${SVC[@]}" \
  -H "Content-Type: application/json" \
  -d '{"p_variant_id":"<uuid>","p_on_hand_delta":50,"p_reserved_delta":0,
       "p_reason":"purchase","p_note":"PO-2291"}'
```

Never write `orders.payment_status` directly — insert the payment row and
let the roll-up decide. That way the ledger and the status can never
disagree.

---

## JS client

```js
// browse
const { data: products } = await client.from('v_product_catalog').select('*')

// my orders -- no filter needed, RLS scopes it
const { data: orders } = await client
  .from('orders')
  .select('*, order_items(*), shipments(tracking_number,status)')
  .order('placed_at', { ascending: false })

// cart and checkout
await client.rpc('add_to_cart', { p_variant_id: variantId, p_quantity: 1 })
const { data: order, error } = await client.rpc('checkout_cart', {
  p_cart_id: cartId, p_shipping_total: 9.0, p_tax_total: 4.5,
})
```

---

## Errors you should expect (and show nicely)

| Situation | Error |
|---|---|
| out of stock at checkout | `check_violation` — *"cannot reserve 3 of variant …: only 1 available"* |
| cancelling someone else's order | `insufficient_privilege` — *"not your order"* |
| cancelling an order that already shipped | `check_violation` — *"order SO-001042 is confirmed and can no longer be cancelled from the app"* |
| checking out an empty cart | *"cart … is empty"* |
| a shopper PATCHing `orders` | HTTP 200, **0 rows updated** — RLS matched nothing |

That last one is the one that catches people out: a policy that hides a row
makes an `UPDATE` a no-op, not an error. Check the affected-row count in the
app, don't assume success.
