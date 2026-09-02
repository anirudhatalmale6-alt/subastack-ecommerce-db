-- =====================================================================
-- 50_seed.sql
-- Demo data for API testing. Idempotent: re-running changes nothing.
--
-- The seed deliberately goes through the real triggers -- orders are
-- created 'pending', lines are added (which reserves stock), then the
-- status is moved forward. So the numbers you see in `inventory` and in
-- orders.payment_status were produced by the same code paths the app
-- will use, not typed in by hand.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------------
insert into categories (name, slug, description, position) values
  ('Electronics',    'electronics',    'Phones, audio, wearables',       1),
  ('Home & Kitchen', 'home-kitchen',   'Everything for the kitchen',     2),
  ('Apparel',        'apparel',        'Clothing and accessories',       3)
on conflict (slug) do nothing;

insert into categories (name, slug, description, position, parent_id)
select v.name, v.slug, v.description, v.position, c.id
from (values
  ('Audio',       'audio',       'Headphones and speakers', 1, 'electronics'),
  ('Wearables',   'wearables',   'Watches and bands',       2, 'electronics'),
  ('Coffee',      'coffee',      'Brewing gear',            1, 'home-kitchen'),
  ('T-Shirts',    't-shirts',    'Tees',                    1, 'apparel'),
  ('Accessories', 'accessories', 'Bags and small leather',  2, 'apparel')
) as v(name, slug, description, position, parent_slug)
join categories c on c.slug = v.parent_slug
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- Products
-- ---------------------------------------------------------------------
insert into products (sku, name, slug, description, brand, status, base_price, currency, weight_grams, category_id, attributes)
select v.sku, v.name, v.slug, v.description, v.brand, v.status::product_status,
       v.base_price, 'USD', v.weight_grams, c.id, v.attributes::jsonb
from (values
  ('AUR-HP-01','Aurora Wireless Headphones','aurora-wireless-headphones','Over-ear ANC headphones, 40h battery.','Aurora','active',199.00,285,'audio','{"anc":true,"battery_hours":40}'),
  ('PLS-SP-01','Pulse Portable Speaker','pulse-portable-speaker','IP67 Bluetooth speaker with 20h playtime.','Pulse','active',89.50,610,'audio','{"waterproof":"IP67"}'),
  ('NMB-EB-01','Nimbus Earbuds','nimbus-earbuds','True wireless earbuds with wireless charging case.','Nimbus','active',129.00,58,'audio','{"anc":true}'),
  ('VTX-SW-02','Vertex Smartwatch S2','vertex-smartwatch-s2','GPS smartwatch with 7-day battery.','Vertex','active',249.00,52,'wearables','{"gps":true}'),
  ('TRH-FB-01','Trailhead Fitness Band','trailhead-fitness-band','Lightweight tracker with sleep staging.','Trailhead','active',59.00,24,'wearables','{"heart_rate":true}'),
  ('BVL-KT-01','Bevel Pour-Over Kettle','bevel-pour-over-kettle','1L gooseneck kettle with variable temperature.','Bevel','active',119.00,1250,'coffee','{"capacity_l":1}'),
  ('GRW-GR-01','Grindwell Burr Grinder','grindwell-burr-grinder','40mm conical burr grinder, 30 settings.','Grindwell','active',149.00,2100,'coffee','{"settings":30}'),
  ('TRA-MG-04','Terra Ceramic Mug Set','terra-ceramic-mug-set','Set of four stoneware mugs.','Terra','active',48.00,1900,'home-kitchen','{"pieces":4}'),
  ('EVD-TS-01','Everyday Cotton Tee','everyday-cotton-tee','240gsm combed cotton tee.','Everyday','active',28.00,180,'t-shirts','{"gsm":240}'),
  ('EVD-HD-01','Heavyweight Hoodie','heavyweight-hoodie','450gsm brushed-back fleece hoodie.','Everyday','active',72.00,700,'apparel','{"gsm":450}'),
  ('CNV-WB-01','Canvas Weekender Bag','canvas-weekender-bag','18oz waxed canvas with leather trim.','Field&Co','active',165.00,1400,'accessories','{"volume_l":38}'),
  ('LTH-CH-01','Leather Card Holder','leather-card-holder','Full-grain leather, four slots.','Field&Co','active',39.00,45,'accessories','{"slots":4}'),
  ('AUR-HP-02','Aurora Studio Monitor','aurora-studio-monitor','Not launched yet -- used to test the draft filter.','Aurora','draft',399.00,4200,'audio','{}')
) as v(sku, name, slug, description, brand, status, base_price, weight_grams, category_slug, attributes)
join categories c on c.slug = v.category_slug
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- Variants
-- ---------------------------------------------------------------------
insert into product_variants (product_id, sku, name, price, compare_at_price, options)
select p.id, v.sku, v.name, v.price, v.compare_at_price, v.options::jsonb
from (values
  ('aurora-wireless-headphones','AUR-HP-01-BLK','Midnight Black',199.00,229.00,'{"color":"black"}'),
  ('aurora-wireless-headphones','AUR-HP-01-SND','Sand',199.00,229.00,'{"color":"sand"}'),
  ('pulse-portable-speaker','PLS-SP-01-DEF','Default',89.50,null,'{}'),
  ('nimbus-earbuds','NMB-EB-01-DEF','Default',129.00,149.00,'{}'),
  ('vertex-smartwatch-s2','VTX-SW-02-40','40mm',249.00,null,'{"size":"40mm"}'),
  ('vertex-smartwatch-s2','VTX-SW-02-44','44mm',269.00,null,'{"size":"44mm"}'),
  ('trailhead-fitness-band','TRH-FB-01-DEF','Default',59.00,null,'{}'),
  ('bevel-pour-over-kettle','BVL-KT-01-DEF','Default',119.00,null,'{}'),
  ('grindwell-burr-grinder','GRW-GR-01-DEF','Default',149.00,169.00,'{}'),
  ('terra-ceramic-mug-set','TRA-MG-04-DEF','Default',48.00,null,'{}'),
  ('everyday-cotton-tee','EVD-TS-01-S','Small / Black',28.00,null,'{"size":"S","color":"black"}'),
  ('everyday-cotton-tee','EVD-TS-01-M','Medium / Black',28.00,null,'{"size":"M","color":"black"}'),
  ('everyday-cotton-tee','EVD-TS-01-L','Large / Black',28.00,null,'{"size":"L","color":"black"}'),
  ('everyday-cotton-tee','EVD-TS-01-XL','X-Large / Black',30.00,null,'{"size":"XL","color":"black"}'),
  ('heavyweight-hoodie','EVD-HD-01-M','Medium',72.00,null,'{"size":"M"}'),
  ('heavyweight-hoodie','EVD-HD-01-L','Large',72.00,null,'{"size":"L"}'),
  ('heavyweight-hoodie','EVD-HD-01-XL','X-Large',75.00,null,'{"size":"XL"}'),
  ('canvas-weekender-bag','CNV-WB-01-DEF','Default',165.00,null,'{}'),
  ('leather-card-holder','LTH-CH-01-TAN','Tan',39.00,null,'{"color":"tan"}'),
  ('leather-card-holder','LTH-CH-01-BLK','Black',39.00,null,'{"color":"black"}'),
  ('aurora-studio-monitor','AUR-HP-02-DEF','Default',399.00,null,'{}')
) as v(product_slug, sku, name, price, compare_at_price, options)
join products p on p.slug = v.product_slug
on conflict (sku) do nothing;

-- ---------------------------------------------------------------------
-- Images (placeholder URLs -- swap for your CDN/storage bucket)
-- ---------------------------------------------------------------------
insert into product_images (product_id, url, alt_text, position)
select p.id,
       'https://cdn.example.com/products/' || p.slug || '-1.jpg',
       p.name || ' main image',
       0
from products p
where not exists (select 1 from product_images pi where pi.product_id = p.id);

-- ---------------------------------------------------------------------
-- Opening stock -- written through apply_stock_movement so the ledger in
-- inventory_movements matches the balances in inventory.
-- ---------------------------------------------------------------------
do $$
declare
  v record;
  qty integer;
begin
  for v in select id, sku from product_variants loop
    if not exists (select 1 from inventory i where i.variant_id = v.id and i.location = 'main') then
      qty := 20 + (abs(hashtext(v.sku)) % 60);          -- 20..79, stable per SKU
      perform public.apply_stock_movement(
        v.id, qty, 0, 'purchase', 'seed', null, 'main', 'opening stock');
      update inventory set reorder_level = 5 where variant_id = v.id and location = 'main';
    end if;
  end loop;
end
$$;

-- One deliberately low line so the reorder report has something in it.
do $$
declare
  vid uuid;
begin
  select id into vid from product_variants where sku = 'NMB-EB-01-DEF';
  if (select quantity_on_hand from inventory where variant_id = vid) > 3 then
    perform public.apply_stock_movement(
      vid,
      3 - (select quantity_on_hand from inventory where variant_id = vid),
      0, 'adjustment', 'seed', null, 'main', 'stock count correction');
  end if;
end
$$;

-- ---------------------------------------------------------------------
-- Customers + addresses
-- ---------------------------------------------------------------------
insert into customers (email, full_name, phone, marketing_opt_in) values
  ('ava.stone@example.com',   'Ava Stone',    '+1-415-555-0142', true),
  ('noah.reyes@example.com',  'Noah Reyes',   '+1-206-555-0188', false),
  ('mia.tanaka@example.com',  'Mia Tanaka',   '+81-3-5555-0110', true),
  ('liam.okafor@example.com', 'Liam Okafor',  '+44-20-5555-0164', false),
  ('sofia.marin@example.com', 'Sofia Marin',  '+34-91-555-0177', true)
on conflict (email) do nothing;

insert into addresses (customer_id, label, recipient_name, phone, line1, city, region, postal_code, country_code, is_default_shipping, is_default_billing)
select c.id, v.label, v.recipient_name, c.phone, v.line1, v.city, v.region, v.postal_code, v.country_code, true, true
from (values
  ('ava.stone@example.com',   'Home',   'Ava Stone',   '18 Dolores St',      'San Francisco', 'CA',    '94110', 'US'),
  ('noah.reyes@example.com',  'Home',   'Noah Reyes',  '904 Pine St Apt 12', 'Seattle',       'WA',    '98101', 'US'),
  ('mia.tanaka@example.com',  'Home',   'Mia Tanaka',  '2-14-5 Shibuya',     'Tokyo',         'Tokyo', '150-0002', 'JP'),
  ('liam.okafor@example.com', 'Office', 'Liam Okafor', '41 Rivington St',    'London',        null,    'EC2A 3QP', 'GB'),
  ('sofia.marin@example.com', 'Home',   'Sofia Marin', 'Calle Serrano 88',   'Madrid',        null,    '28006', 'ES')
) as v(email, label, recipient_name, line1, city, region, postal_code, country_code)
join customers c on c.email = v.email
where not exists (select 1 from addresses a where a.customer_id = c.id);

-- ---------------------------------------------------------------------
-- Orders. Each one is created pending, filled, then moved forward so the
-- stock and payment triggers do the accounting.
-- ---------------------------------------------------------------------
do $$
declare
  spec record;
  ord_id uuid;
  cust customers%rowtype;
  addr jsonb;
  item record;
begin
  for spec in
    select * from (values
      -- number,       email,                     status,      fulfillment,     payment scenario, shipping, tax
      ('SEED-0001','ava.stone@example.com',  'pending',   'unfulfilled', 'none',      9.00,  16.50),
      ('SEED-0002','noah.reyes@example.com', 'confirmed', 'unfulfilled', 'captured',  0.00,  12.00),
      ('SEED-0003','mia.tanaka@example.com', 'confirmed', 'fulfilled',   'captured', 14.00,  21.00),
      ('SEED-0004','liam.okafor@example.com','completed', 'fulfilled',   'captured', 12.00,  38.40),
      ('SEED-0005','sofia.marin@example.com','cancelled', 'unfulfilled', 'failed',    9.00,   7.20),
      ('SEED-0006','ava.stone@example.com',  'completed', 'fulfilled',   'partial_refund', 0.00, 5.60)
    ) as t(order_number, email, target_status, target_fulfillment, payment_case, shipping_total, tax_total)
  loop
    if exists (select 1 from orders o where o.order_number = spec.order_number) then
      continue;
    end if;

    select * into cust from customers c where c.email = spec.email;
    select to_jsonb(a) - 'id' - 'customer_id' - 'created_at' - 'updated_at'
      into addr from addresses a where a.customer_id = cust.id limit 1;

    insert into orders (order_number, customer_id, email, currency, shipping_address, billing_address,
                        shipping_total, tax_total, placed_at)
    values (spec.order_number, cust.id, cust.email, 'USD', addr, addr,
            spec.shipping_total, spec.tax_total,
            now() - (interval '1 day' * (7 - right(spec.order_number, 1)::int)))
    returning id into ord_id;

    -- two lines per order, picked deterministically from the catalogue
    for item in
      select pv.id as variant_id, pv.sku, pv.name as variant_name, pv.price, p.name as product_name,
             1 + (abs(hashtext(spec.order_number || pv.sku)) % 2) as qty
        from product_variants pv
        join products p on p.id = pv.product_id
       where p.status = 'active'
       order by md5(spec.order_number || pv.sku)
       limit 2
    loop
      insert into order_items (order_id, variant_id, sku, product_name, variant_name, unit_price, quantity)
      values (ord_id, item.variant_id, item.sku, item.product_name, item.variant_name, item.price, item.qty);
    end loop;

    -- payments
    if spec.payment_case = 'captured' then
      insert into payments (order_id, provider, provider_reference, method, amount, currency, status, processed_at)
      select ord_id, 'stripe', 'pi_' || replace(spec.order_number, '-', '_'), 'card',
             o.grand_total, 'USD', 'captured', o.placed_at + interval '2 minutes'
      from orders o where o.id = ord_id;

    elsif spec.payment_case = 'failed' then
      insert into payments (order_id, provider, provider_reference, method, amount, currency, status, error_message, processed_at)
      select ord_id, 'stripe', 'pi_' || replace(spec.order_number, '-', '_'), 'card',
             o.grand_total, 'USD', 'failed', 'card_declined', o.placed_at + interval '1 minute'
      from orders o where o.id = ord_id;

    elsif spec.payment_case = 'partial_refund' then
      insert into payments (order_id, provider, provider_reference, method, amount, currency, status, processed_at)
      select ord_id, 'stripe', 'pi_' || replace(spec.order_number, '-', '_'), 'card',
             o.grand_total, 'USD', 'captured', o.placed_at + interval '2 minutes'
      from orders o where o.id = ord_id;

      insert into payments (order_id, provider, provider_reference, method, amount, currency, status, processed_at)
      select ord_id, 'stripe', 're_' || replace(spec.order_number, '-', '_'), 'card',
             -round(o.grand_total * 0.25, 2), 'USD', 'refunded', o.placed_at + interval '3 days'
      from orders o where o.id = ord_id;
    end if;

    -- move the order forward; triggers handle stock + history
    update orders
       set status = spec.target_status::order_status,
           fulfillment_status = spec.target_fulfillment::fulfillment_status
     where id = ord_id;

    -- shipment for anything fulfilled
    if spec.target_fulfillment = 'fulfilled' then
      insert into shipments (order_id, carrier, service, tracking_number, status, shipped_at, delivered_at)
      values (ord_id, 'DHL', 'Express',
              'DHL' || lpad((abs(hashtext(spec.order_number)) % 1000000)::text, 9, '0'),
              (case when spec.target_status = 'completed' then 'delivered' else 'in_transit' end)::shipment_status,
              now() - interval '3 days',
              case when spec.target_status = 'completed' then now() - interval '1 day' else null end);

      insert into shipment_items (shipment_id, order_item_id, quantity)
      select s.id, oi.id, oi.quantity
        from shipments s join order_items oi on oi.order_id = s.order_id
       where s.order_id = ord_id
      on conflict do nothing;
    end if;
  end loop;
end
$$;

commit;
