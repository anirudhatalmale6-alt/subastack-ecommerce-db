-- =====================================================================
-- 15_views.sql
-- Read models exposed on the API.
--
-- Two deliberately different security modes:
--
--  * v_available_stock  -- owner rights (the default). It bypasses RLS on
--    `inventory` on purpose and exposes ONLY availability, never the real
--    on-hand/reserved numbers. This is how the storefront shows
--    "3 left" without granting anyone a read on the inventory table.
--
--  * v_inventory_status, v_order_summary -- security_invoker = true, so
--    the caller's own RLS policies apply. Staff see everything; a signed
--    in shopper sees their own rows (or nothing) with no extra plumbing.
-- =====================================================================

-- Storefront: availability of sellable variants only.
create or replace view v_available_stock as
select
  pv.id                                              as variant_id,
  pv.product_id,
  pv.sku,
  greatest(i.quantity_on_hand - i.quantity_reserved, 0) as quantity_available,
  (i.quantity_on_hand - i.quantity_reserved) > 0     as in_stock
from product_variants pv
join inventory i on i.variant_id = pv.id and i.location = 'main'
join products p  on p.id = pv.product_id
where pv.is_active and p.status = 'active';

-- Back office: the real numbers. RLS on `inventory` limits this to staff.
create or replace view v_inventory_status
with (security_invoker = true) as
select
  i.variant_id,
  pv.product_id,
  p.name        as product_name,
  pv.sku,
  pv.name       as variant_name,
  i.location,
  i.quantity_on_hand,
  i.quantity_reserved,
  (i.quantity_on_hand - i.quantity_reserved) as quantity_available,
  i.reorder_level,
  (i.quantity_on_hand - i.quantity_reserved) <= i.reorder_level as needs_reorder,
  i.updated_at
from inventory i
join product_variants pv on pv.id = i.variant_id
join products p on p.id = pv.product_id;

-- One row per order with the item count rolled up. RLS applies, so a
-- shopper reading this gets exactly their own orders.
create or replace view v_order_summary
with (security_invoker = true) as
select
  o.id,
  o.order_number,
  o.customer_id,
  o.email,
  o.status,
  o.payment_status,
  o.fulfillment_status,
  o.currency,
  o.subtotal,
  o.discount_total,
  o.shipping_total,
  o.tax_total,
  o.grand_total,
  o.placed_at,
  count(oi.id)                        as item_count,
  coalesce(sum(oi.quantity), 0)       as unit_count
from orders o
left join order_items oi on oi.order_id = o.id
group by o.id;

-- Catalogue read model: product + its cheapest active variant + stock.
create or replace view v_product_catalog as
select
  p.id,
  p.sku,
  p.name,
  p.slug,
  p.description,
  p.brand,
  p.currency,
  p.attributes,
  c.id    as category_id,
  c.name  as category_name,
  c.slug  as category_slug,
  min(pv.price)                                   as from_price,
  count(pv.id) filter (where pv.is_active)        as variant_count,
  coalesce(sum(greatest(i.quantity_on_hand - i.quantity_reserved, 0)), 0) as quantity_available,
  (select url from product_images pi
    where pi.product_id = p.id order by pi.position limit 1) as primary_image_url
from products p
left join categories c on c.id = p.category_id
left join product_variants pv on pv.product_id = p.id and pv.is_active
left join inventory i on i.variant_id = pv.id and i.location = 'main'
where p.status = 'active'
group by p.id, c.id;
