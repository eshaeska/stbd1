CREATE OR REPLACE FUNCTION fn_driver_license_valid(p_driver_id BIGINT, p_on DATE DEFAULT CURRENT_DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM drivers
                   WHERE driver_id = p_driver_id AND NOT is_deleted AND license_expiry >= p_on);
$$;

CREATE OR REPLACE FUNCTION fn_driver_has_category(p_driver_id BIGINT, p_category_id INT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT p_category_id IS NULL
        OR EXISTS (SELECT 1 FROM driver_license_categories
                   WHERE driver_id = p_driver_id AND category_id = p_category_id);
$$;

CREATE OR REPLACE FUNCTION fn_is_vehicle_insured(p_vehicle_id BIGINT, p_on DATE DEFAULT CURRENT_DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM insurance_policies
                   WHERE vehicle_id = p_vehicle_id AND NOT is_deleted
                     AND policy_type = 'OSAGO' AND p_on BETWEEN valid_from AND valid_to);
$$;

CREATE OR REPLACE FUNCTION fn_vehicle_avg_consumption(p_vehicle_id BIGINT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_liters NUMERIC; v_km NUMERIC;
BEGIN
    SELECT COALESCE(SUM(liters), 0) INTO v_liters FROM fuel_records WHERE vehicle_id = p_vehicle_id;
    SELECT COALESCE(SUM(end_odometer_km - start_odometer_km), 0) INTO v_km
      FROM trips WHERE vehicle_id = p_vehicle_id AND status = 'COMPLETED';
    RETURN ROUND(v_liters / NULLIF(v_km, 0) * 100, 2);
END $$;

CREATE OR REPLACE FUNCTION fn_vehicle_total_cost(p_vehicle_id BIGINT,
        p_from DATE DEFAULT DATE '1900-01-01', p_to DATE DEFAULT DATE '2999-12-31')
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT SUM(total_cost) FROM fuel_records
                      WHERE vehicle_id = p_vehicle_id AND fueled_at::date BETWEEN p_from AND p_to), 0)
         + COALESCE((SELECT SUM(cost) FROM maintenance_orders
                      WHERE vehicle_id = p_vehicle_id AND status = 'COMPLETED'
                        AND opened_at::date BETWEEN p_from AND p_to), 0)
         + COALESCE((SELECT SUM(amount) FROM fines
                      WHERE vehicle_id = p_vehicle_id AND fine_date BETWEEN p_from AND p_to), 0);
$$;

CREATE OR REPLACE FUNCTION trg_touch_updated_at() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['users','drivers','vehicles','trips','fuel_records','maintenance_orders','insurance_policies']
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_touch BEFORE UPDATE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at()', t, t);
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION trg_forbid_hard_delete() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Фізичне видалення з % заборонене. Використовуйте soft delete.', TG_TABLE_NAME;
END $$;

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['users','drivers','vehicles','insurance_policies','service_stations']
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_nodelete BEFORE DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_forbid_hard_delete()', t, t);
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION trg_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log(table_name, record_id, action, old_data, new_data, changed_by)
    VALUES (TG_TABLE_NAME,
            (to_jsonb(NEW) ->> TG_ARGV[0])::BIGINT,
            TG_OP,
            CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) END,
            to_jsonb(NEW),
            (to_jsonb(NEW) ->> 'updated_by')::BIGINT);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_vehicles_audit AFTER INSERT OR UPDATE ON vehicles
    FOR EACH ROW EXECUTE FUNCTION trg_audit('vehicle_id');
CREATE TRIGGER trg_drivers_audit AFTER INSERT OR UPDATE ON drivers
    FOR EACH ROW EXECUTE FUNCTION trg_audit('driver_id');

CREATE OR REPLACE FUNCTION trg_trip_sync_vehicle() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'IN_PROGRESS' THEN
        UPDATE vehicles SET status_id = (SELECT status_id FROM vehicle_statuses WHERE code = 'IN_TRIP'),
                            updated_by = COALESCE(NEW.updated_by, updated_by)
        WHERE vehicle_id = NEW.vehicle_id;
    ELSIF NEW.status = 'COMPLETED' THEN
        UPDATE vehicles SET status_id = (SELECT status_id FROM vehicle_statuses WHERE code = 'AVAILABLE'),
                            odometer_km = GREATEST(odometer_km, NEW.end_odometer_km),
                            updated_by = COALESCE(NEW.updated_by, updated_by)
        WHERE vehicle_id = NEW.vehicle_id;
    ELSE -- CANCELLED
        UPDATE vehicles SET status_id = (SELECT status_id FROM vehicle_statuses WHERE code = 'AVAILABLE'),
                            updated_by = COALESCE(NEW.updated_by, updated_by)
        WHERE vehicle_id = NEW.vehicle_id;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_trips_sync_vehicle AFTER INSERT OR UPDATE OF status ON trips
    FOR EACH ROW EXECUTE FUNCTION trg_trip_sync_vehicle();

CREATE OR REPLACE FUNCTION trg_fuel_validate() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_tank NUMERIC; v_deleted BOOLEAN;
BEGIN
    SELECT tank_capacity_l, is_deleted INTO v_tank, v_deleted FROM vehicles WHERE vehicle_id = NEW.vehicle_id;
    IF v_deleted THEN RAISE EXCEPTION 'Авто % видалене', NEW.vehicle_id; END IF;
    IF v_tank IS NOT NULL AND NEW.liters > v_tank THEN
        RAISE EXCEPTION 'Заправка % л перевищує ємність бака % л', NEW.liters, v_tank;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_fuel_validate BEFORE INSERT OR UPDATE ON fuel_records
    FOR EACH ROW EXECUTE FUNCTION trg_fuel_validate();

CREATE OR REPLACE FUNCTION trg_maintenance_sync_vehicle() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('OPEN','IN_PROGRESS') THEN
        UPDATE vehicles SET status_id = (SELECT status_id FROM vehicle_statuses WHERE code = 'MAINTENANCE'),
                            updated_by = COALESCE(NEW.updated_by, updated_by)
        WHERE vehicle_id = NEW.vehicle_id;
    ELSE
        UPDATE vehicles SET status_id = (SELECT status_id FROM vehicle_statuses WHERE code = 'AVAILABLE'),
                            updated_by = COALESCE(NEW.updated_by, updated_by)
        WHERE vehicle_id = NEW.vehicle_id
          AND status_id = (SELECT status_id FROM vehicle_statuses WHERE code = 'MAINTENANCE');
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_maintenance_sync AFTER INSERT OR UPDATE OF status ON maintenance_orders
    FOR EACH ROW EXECUTE FUNCTION trg_maintenance_sync_vehicle();

CREATE OR REPLACE VIEW vw_active_vehicles AS
SELECT v.vehicle_id, v.vin::VARCHAR AS vin, v.plate_number, b.name AS brand, m.name AS model,
       ft.name AS fuel_type, s.code AS status, v.odometer_km, v.manufacture_year,
       fn_is_vehicle_insured(v.vehicle_id) AS is_insured,
       v.updated_at, v.updated_by
FROM vehicles v
JOIN vehicle_models m   ON m.model_id = v.model_id
JOIN vehicle_brands b   ON b.brand_id = m.brand_id
JOIN fuel_types ft      ON ft.fuel_type_id = v.fuel_type_id
JOIN vehicle_statuses s ON s.status_id = v.status_id
WHERE NOT v.is_deleted;

CREATE OR REPLACE VIEW vw_active_drivers AS
SELECT d.driver_id, d.last_name || ' ' || d.first_name AS full_name, COALESCE(d.phone, '') AS phone,
       d.license_number, d.license_expiry, fn_driver_license_valid(d.driver_id) AS license_valid,
       COALESCE((SELECT string_agg(c.code, ',' ORDER BY c.code)
                 FROM driver_license_categories dc JOIN license_categories c USING (category_id)
                 WHERE dc.driver_id = d.driver_id), '') AS categories,
       d.updated_at, d.updated_by
FROM drivers d
WHERE NOT d.is_deleted;

CREATE OR REPLACE VIEW vw_trip_details AS
SELECT t.trip_id, t.vehicle_id, t.driver_id, v.plate_number,
       d.last_name || ' ' || d.first_name AS driver_name,
       COALESCE(t.purpose, '') AS purpose, t.start_location, t.end_location,
       t.started_at, t.finished_at,
       t.end_odometer_km - t.start_odometer_km AS distance_km, t.status
FROM trips t
JOIN vehicles v ON v.vehicle_id = t.vehicle_id
JOIN drivers d  ON d.driver_id  = t.driver_id;

CREATE OR REPLACE VIEW vw_vehicle_costs AS
SELECT v.vehicle_id, v.plate_number,
       COALESCE((SELECT SUM(total_cost) FROM fuel_records WHERE vehicle_id = v.vehicle_id), 0) AS fuel_cost,
       COALESCE((SELECT SUM(cost) FROM maintenance_orders
                 WHERE vehicle_id = v.vehicle_id AND status = 'COMPLETED'), 0) AS maintenance_cost,
       COALESCE((SELECT SUM(amount) FROM fines WHERE vehicle_id = v.vehicle_id), 0) AS fines_cost,
       fn_vehicle_total_cost(v.vehicle_id) AS total_cost,
       fn_vehicle_avg_consumption(v.vehicle_id) AS avg_consumption_l100
FROM vehicles v
WHERE NOT v.is_deleted;

CREATE OR REPLACE VIEW vw_expiring_documents AS
SELECT 'DRIVER_LICENSE' AS doc_type, d.driver_id AS owner_id,
       d.last_name || ' ' || d.first_name AS owner_name, d.license_expiry AS valid_to
FROM drivers d
WHERE NOT d.is_deleted AND d.license_expiry <= CURRENT_DATE + 30
UNION ALL
SELECT 'INSURANCE_' || p.policy_type, p.vehicle_id, v.plate_number, p.valid_to
FROM insurance_policies p JOIN vehicles v USING (vehicle_id)
WHERE NOT p.is_deleted AND NOT v.is_deleted AND p.valid_to <= CURRENT_DATE + 30;

CREATE OR REPLACE FUNCTION sp_vehicle_create(p_model_id INT, p_fuel_type_id INT, p_vin VARCHAR,
        p_plate VARCHAR, p_year INT, p_color VARCHAR, p_tank NUMERIC, p_odometer NUMERIC, p_user_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO vehicles(model_id, fuel_type_id, vin, plate_number, manufacture_year, color,
                         tank_capacity_l, odometer_km, updated_by)
    VALUES (p_model_id, p_fuel_type_id, p_vin, p_plate, p_year, p_color,
            p_tank, COALESCE(p_odometer, 0), p_user_id)
    RETURNING vehicle_id INTO v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE PROCEDURE sp_vehicle_update(p_vehicle_id BIGINT, p_plate VARCHAR, p_color VARCHAR,
        p_status_id INT, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE vehicles
    SET plate_number = COALESCE(p_plate, plate_number),
        color        = COALESCE(p_color, color),
        status_id    = COALESCE(p_status_id, status_id),
        updated_by   = p_user_id
    WHERE vehicle_id = p_vehicle_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Авто % не знайдено', p_vehicle_id; END IF;
END $$;

CREATE OR REPLACE PROCEDURE sp_vehicle_soft_delete(p_vehicle_id BIGINT, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM trips WHERE vehicle_id = p_vehicle_id AND status = 'IN_PROGRESS') THEN
        RAISE EXCEPTION 'Авто % у рейсі, видалення неможливе', p_vehicle_id;
    END IF;
    UPDATE vehicles SET is_deleted = TRUE, deleted_at = now(), deleted_by = p_user_id, updated_by = p_user_id
    WHERE vehicle_id = p_vehicle_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Авто % не знайдено або вже видалене', p_vehicle_id; END IF;
END $$;

CREATE OR REPLACE PROCEDURE sp_vehicle_restore(p_vehicle_id BIGINT, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE vehicles SET is_deleted = FALSE, deleted_at = NULL, deleted_by = NULL, updated_by = p_user_id
    WHERE vehicle_id = p_vehicle_id AND is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Авто % не знайдено серед видалених', p_vehicle_id; END IF;
END $$;

CREATE OR REPLACE FUNCTION sp_driver_create(p_first VARCHAR, p_last VARCHAR, p_phone VARCHAR,
        p_license_number VARCHAR, p_license_expiry DATE, p_hired_at DATE, p_user_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT;
BEGIN
    IF p_license_expiry < CURRENT_DATE THEN
        RAISE EXCEPTION 'Посвідчення водія прострочене (%)', p_license_expiry;
    END IF;
    INSERT INTO drivers(first_name, last_name, phone, license_number, license_expiry, hired_at, updated_by)
    VALUES (p_first, p_last, p_phone, p_license_number, p_license_expiry,
            COALESCE(p_hired_at, CURRENT_DATE), p_user_id)
    RETURNING driver_id INTO v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE PROCEDURE sp_driver_update(p_driver_id BIGINT, p_phone VARCHAR, p_license_expiry DATE,
        p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE drivers
    SET phone = COALESCE(p_phone, phone),
        license_expiry = COALESCE(p_license_expiry, license_expiry),
        updated_by = p_user_id
    WHERE driver_id = p_driver_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Водія % не знайдено', p_driver_id; END IF;
END $$;

CREATE OR REPLACE PROCEDURE sp_driver_add_category(p_driver_id BIGINT, p_category_code VARCHAR, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
DECLARE v_cat INT;
BEGIN
    SELECT category_id INTO v_cat FROM license_categories WHERE code = p_category_code;
    IF v_cat IS NULL THEN RAISE EXCEPTION 'Невідома категорія %', p_category_code; END IF;
    INSERT INTO driver_license_categories(driver_id, category_id, obtained_at)
    VALUES (p_driver_id, v_cat, CURRENT_DATE) ON CONFLICT DO NOTHING;
    UPDATE drivers SET updated_by = p_user_id WHERE driver_id = p_driver_id; -- фіксуємо хто змінив
END $$;

CREATE OR REPLACE PROCEDURE sp_driver_soft_delete(p_driver_id BIGINT, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM trips WHERE driver_id = p_driver_id AND status = 'IN_PROGRESS') THEN
        RAISE EXCEPTION 'Водій % має незавершений рейс', p_driver_id;
    END IF;
    UPDATE drivers SET is_deleted = TRUE, deleted_at = now(), deleted_by = p_user_id, updated_by = p_user_id
    WHERE driver_id = p_driver_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Водія % не знайдено або вже видалений', p_driver_id; END IF;
    UPDATE vehicle_assignments SET returned_at = now()
    WHERE driver_id = p_driver_id AND returned_at IS NULL;
END $$;

CREATE OR REPLACE PROCEDURE sp_driver_restore(p_driver_id BIGINT, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE drivers SET is_deleted = FALSE, deleted_at = NULL, deleted_by = NULL, updated_by = p_user_id
    WHERE driver_id = p_driver_id AND is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Водія % не знайдено серед видалених', p_driver_id; END IF;
END $$;

CREATE OR REPLACE FUNCTION sp_assign_vehicle(p_vehicle_id BIGINT, p_driver_id BIGINT, p_user_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT;
BEGIN
    UPDATE vehicle_assignments SET returned_at = now()
    WHERE vehicle_id = p_vehicle_id AND returned_at IS NULL;
    INSERT INTO vehicle_assignments(vehicle_id, driver_id) VALUES (p_vehicle_id, p_driver_id)
    RETURNING assignment_id INTO v_id;
    UPDATE vehicles SET updated_by = p_user_id WHERE vehicle_id = p_vehicle_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION sp_trip_start(p_vehicle_id BIGINT, p_driver_id BIGINT, p_purpose VARCHAR,
        p_start_location VARCHAR, p_end_location VARCHAR, p_user_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_odo NUMERIC; v_status VARCHAR; v_req_cat INT; v_id BIGINT;
BEGIN
    SELECT v.odometer_km, s.code, m.required_category_id
      INTO v_odo, v_status, v_req_cat
    FROM vehicles v
    JOIN vehicle_statuses s ON s.status_id = v.status_id
    JOIN vehicle_models m   ON m.model_id = v.model_id
    WHERE v.vehicle_id = p_vehicle_id AND NOT v.is_deleted
    FOR UPDATE OF v;

    IF v_status IS NULL THEN RAISE EXCEPTION 'Авто % не знайдено', p_vehicle_id; END IF;
    IF v_status <> 'AVAILABLE' THEN RAISE EXCEPTION 'Авто % недоступне (статус %)', p_vehicle_id, v_status; END IF;
    IF NOT fn_driver_license_valid(p_driver_id) THEN
        RAISE EXCEPTION 'У водія % немає чинного посвідчення', p_driver_id;
    END IF;
    IF NOT fn_driver_has_category(p_driver_id, v_req_cat) THEN
        RAISE EXCEPTION 'Водій % не має потрібної категорії', p_driver_id;
    END IF;

    INSERT INTO trips(vehicle_id, driver_id, purpose, start_location, end_location,
                      start_odometer_km, status, created_by, updated_by)
    VALUES (p_vehicle_id, p_driver_id, p_purpose, p_start_location, p_end_location,
            v_odo, 'IN_PROGRESS', p_user_id, p_user_id)
    RETURNING trip_id INTO v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE PROCEDURE sp_trip_finish(p_trip_id BIGINT, p_end_odometer NUMERIC, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE trips SET status = 'COMPLETED', finished_at = now(),
                     end_odometer_km = p_end_odometer, updated_by = p_user_id
    WHERE trip_id = p_trip_id AND status = 'IN_PROGRESS';
    IF NOT FOUND THEN RAISE EXCEPTION 'Активний рейс % не знайдено', p_trip_id; END IF;
END $$;

CREATE OR REPLACE PROCEDURE sp_trip_cancel(p_trip_id BIGINT, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE trips SET status = 'CANCELLED', finished_at = now(), updated_by = p_user_id
    WHERE trip_id = p_trip_id AND status = 'IN_PROGRESS';
    IF NOT FOUND THEN RAISE EXCEPTION 'Активний рейс % не знайдено', p_trip_id; END IF;
END $$;

CREATE OR REPLACE FUNCTION sp_fuel_add(p_vehicle_id BIGINT, p_driver_id BIGINT, p_station_id INT,
        p_liters NUMERIC, p_price NUMERIC, p_odometer NUMERIC, p_user_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_fuel INT;
BEGIN
    SELECT fuel_type_id INTO v_fuel FROM vehicles WHERE vehicle_id = p_vehicle_id AND NOT is_deleted;
    IF v_fuel IS NULL THEN RAISE EXCEPTION 'Авто % не знайдено', p_vehicle_id; END IF;
    INSERT INTO fuel_records(vehicle_id, driver_id, station_id, fuel_type_id, liters, price_per_liter,
                             odometer_km, updated_by)
    VALUES (p_vehicle_id, p_driver_id, p_station_id, v_fuel, p_liters, p_price, p_odometer, p_user_id)
    RETURNING fuel_id INTO v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION sp_maintenance_open(p_vehicle_id BIGINT, p_type_id INT, p_service_id INT,
        p_description TEXT, p_user_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_odo NUMERIC;
BEGIN
    IF EXISTS (SELECT 1 FROM trips WHERE vehicle_id = p_vehicle_id AND status = 'IN_PROGRESS') THEN
        RAISE EXCEPTION 'Авто % у рейсі', p_vehicle_id;
    END IF;
    SELECT odometer_km INTO v_odo FROM vehicles WHERE vehicle_id = p_vehicle_id AND NOT is_deleted;
    IF v_odo IS NULL THEN RAISE EXCEPTION 'Авто % не знайдено', p_vehicle_id; END IF;
    INSERT INTO maintenance_orders(vehicle_id, type_id, service_id, odometer_km, description, status, updated_by)
    VALUES (p_vehicle_id, p_type_id, p_service_id, v_odo, p_description, 'IN_PROGRESS', p_user_id)
    RETURNING order_id INTO v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE PROCEDURE sp_maintenance_close(p_order_id BIGINT, p_cost NUMERIC, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE maintenance_orders SET status = 'COMPLETED', closed_at = now(), cost = p_cost, updated_by = p_user_id
    WHERE order_id = p_order_id AND status IN ('OPEN','IN_PROGRESS');
    IF NOT FOUND THEN RAISE EXCEPTION 'Відкрите замовлення % не знайдено', p_order_id; END IF;
END $$;

CREATE OR REPLACE FUNCTION sp_policy_add(p_vehicle_id BIGINT, p_company_id INT, p_number VARCHAR,
        p_type VARCHAR, p_from DATE, p_to DATE, p_premium NUMERIC, p_user_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO insurance_policies(vehicle_id, company_id, policy_number, policy_type,
                                   valid_from, valid_to, premium, updated_by)
    VALUES (p_vehicle_id, p_company_id, p_number, p_type, p_from, p_to, p_premium, p_user_id)
    RETURNING policy_id INTO v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE PROCEDURE sp_policy_soft_delete(p_policy_id BIGINT, p_user_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE insurance_policies SET is_deleted = TRUE, deleted_at = now(), deleted_by = p_user_id,
                                  updated_by = p_user_id
    WHERE policy_id = p_policy_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Поліс % не знайдено', p_policy_id; END IF;
END $$;
