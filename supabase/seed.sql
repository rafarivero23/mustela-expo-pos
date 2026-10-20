-- Example catalog (placeholder prices). Replace from the Inventario screen before the event.
insert into public.products (name, category, size, price, stock, sort_order, sample) values
  ('Hydra Bébé Crema Corporal',             'Bebé',         '300 ml',   389, 40,  1, true),
  ('Gel Lavante Suave',                     'Bebé',         '500 ml',   359, 40,  2, true),
  ('Crema para Cambio de Pañal 1 2 3',      'Bebé',         '100 ml',   279, 50,  3, true),
  ('Agua Limpiadora sin Enjuague',          'Bebé',         '300 ml',   299, 30,  4, true),
  ('Champú Espuma Recién Nacido',           'Bebé',         '150 ml',   319, 25,  5, true),
  ('Stelatopia Crema Emoliente',            'Piel atópica', '200 ml',   529, 24,  6, true),
  ('Stelatopia Aceite de Baño',             'Piel atópica', '200 ml',   489, 20,  7, true),
  ('Maternité Crema Prevención de Estrías', 'Maternidad',   '150 ml',   649, 20,  8, true),
  ('Maternité Aceite para Estrías',         'Maternidad',   '105 ml',   599, 15,  9, true),
  ('Kit Bienvenida Recién Nacido',          'Kits',         '4 piezas', 999, 12, 10, true);

-- Staff allowlist: add every person who will use Caja / Surtido / Inventario.
-- They also need a user in Authentication → Users with the same email.
insert into public.staff (email, nombre) values
  ('cambia-esto@optimistinc.mx', 'Admin')
on conflict do nothing;
