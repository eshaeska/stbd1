
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE UNIQUE INDEX ux_vehicles_vin     ON vehicles (vin)          WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_vehicles_plate   ON vehicles (plate_number) WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_drivers_license  ON drivers  (license_number) WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_users_login      ON users    (login)        WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_policies_number  ON insurance_policies (policy_number) WHERE NOT is_deleted;

CREATE UNIQUE INDEX ux_trips_active_vehicle ON trips (vehicle_id) WHERE status = 'IN_PROGRESS';
CREATE UNIQUE INDEX ux_trips_active_driver  ON trips (driver_id)  WHERE status = 'IN_PROGRESS';
CREATE UNIQUE INDEX ux_assign_active        ON vehicle_assignments (vehicle_id) WHERE returned_at IS NULL;

CREATE INDEX ix_trips_vehicle_started ON trips (vehicle_id, started_at DESC);
CREATE INDEX ix_trips_driver_started  ON trips (driver_id, started_at DESC);
CREATE INDEX ix_policies_vehicle_to   ON insurance_policies (vehicle_id, valid_to) WHERE NOT is_deleted;
CREATE INDEX ix_fuel_vehicle_time     ON fuel_records (vehicle_id, fueled_at DESC);
CREATE INDEX ix_maint_vehicle         ON maintenance_orders (vehicle_id, status);
CREATE INDEX ix_fines_vehicle         ON fines (vehicle_id);

CREATE INDEX hx_users_login ON users USING HASH (login);

CREATE INDEX gx_drivers_fullname_trgm ON drivers
    USING GIN ((last_name || ' ' || first_name) gin_trgm_ops) WHERE NOT is_deleted;

CREATE INDEX bx_fuel_fueled_at     ON fuel_records USING BRIN (fueled_at);
CREATE INDEX bx_audit_changed_at   ON audit_log    USING BRIN (changed_at);

