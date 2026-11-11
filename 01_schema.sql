CREATE TABLE roles (
    role_id     SERIAL PRIMARY KEY,
    name        VARCHAR(50) NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE users (
    user_id       BIGSERIAL PRIMARY KEY,
    role_id       INT NOT NULL REFERENCES roles(role_id),
    login         VARCHAR(50)  NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name     VARCHAR(150) NOT NULL,
    email         VARCHAR(150),
    is_deleted    BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at    TIMESTAMPTZ,
    deleted_by    BIGINT REFERENCES users(user_id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by    BIGINT REFERENCES users(user_id)
);

CREATE TABLE license_categories (
    category_id SERIAL PRIMARY KEY,
    code        VARCHAR(5) NOT NULL UNIQUE,
    description VARCHAR(100)
);

CREATE TABLE drivers (
    driver_id      BIGSERIAL PRIMARY KEY,
    user_id        BIGINT UNIQUE REFERENCES users(user_id),
    first_name     VARCHAR(60) NOT NULL,
    last_name      VARCHAR(60) NOT NULL,
    phone          VARCHAR(20),
    license_number VARCHAR(20) NOT NULL,
    license_expiry DATE NOT NULL,
    hired_at       DATE NOT NULL DEFAULT CURRENT_DATE,
    is_deleted     BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at     TIMESTAMPTZ,
    deleted_by     BIGINT REFERENCES users(user_id),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     BIGINT REFERENCES users(user_id)
);

CREATE TABLE driver_license_categories (
    driver_id   BIGINT NOT NULL REFERENCES drivers(driver_id),
    category_id INT    NOT NULL REFERENCES license_categories(category_id),
    obtained_at DATE,
    PRIMARY KEY (driver_id, category_id)
);

CREATE TABLE vehicle_brands (
    brand_id SERIAL PRIMARY KEY,
    name     VARCHAR(60) NOT NULL UNIQUE
);

CREATE TABLE vehicle_models (
    model_id             SERIAL PRIMARY KEY,
    brand_id             INT NOT NULL REFERENCES vehicle_brands(brand_id),
    name                 VARCHAR(60) NOT NULL,
    body_type            VARCHAR(30),
    seats                INT CHECK (seats > 0),
    required_category_id INT REFERENCES license_categories(category_id),
    UNIQUE (brand_id, name)
);

CREATE TABLE fuel_types (
    fuel_type_id SERIAL PRIMARY KEY,
    name         VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE vehicle_statuses (
    status_id SERIAL PRIMARY KEY,
    code      VARCHAR(20) NOT NULL UNIQUE,
    name      VARCHAR(60) NOT NULL
);

CREATE TABLE vehicles (
    vehicle_id       BIGSERIAL PRIMARY KEY,
    model_id         INT NOT NULL REFERENCES vehicle_models(model_id),
    fuel_type_id     INT NOT NULL REFERENCES fuel_types(fuel_type_id),
    status_id        INT NOT NULL DEFAULT 1 REFERENCES vehicle_statuses(status_id),
    vin              CHAR(17)    NOT NULL,
    plate_number     VARCHAR(15) NOT NULL,
    manufacture_year INT NOT NULL CHECK (manufacture_year BETWEEN 1980 AND 2100),
    color            VARCHAR(30),
    odometer_km      NUMERIC(10,1) NOT NULL DEFAULT 0 CHECK (odometer_km >= 0),
    tank_capacity_l  NUMERIC(6,1) CHECK (tank_capacity_l > 0),
    purchase_date    DATE,
    purchase_price   NUMERIC(12,2) CHECK (purchase_price >= 0),
    is_deleted       BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at       TIMESTAMPTZ,
    deleted_by       BIGINT REFERENCES users(user_id),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by       BIGINT REFERENCES users(user_id)
);

CREATE TABLE vehicle_assignments (
    assignment_id BIGSERIAL PRIMARY KEY,
    vehicle_id    BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
    driver_id     BIGINT NOT NULL REFERENCES drivers(driver_id),
    assigned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    returned_at   TIMESTAMPTZ,
    CHECK (returned_at IS NULL OR returned_at > assigned_at)
);

CREATE TABLE trips (
    trip_id           BIGSERIAL PRIMARY KEY,
    vehicle_id        BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
    driver_id         BIGINT NOT NULL REFERENCES drivers(driver_id),
    purpose           VARCHAR(200),
    start_location    VARCHAR(150) NOT NULL,
    end_location      VARCHAR(150) NOT NULL,
    started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at       TIMESTAMPTZ,
    start_odometer_km NUMERIC(10,1) NOT NULL,
    end_odometer_km   NUMERIC(10,1),
    status            VARCHAR(12) NOT NULL DEFAULT 'IN_PROGRESS'
                      CHECK (status IN ('IN_PROGRESS','COMPLETED','CANCELLED')),
    created_by        BIGINT REFERENCES users(user_id),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        BIGINT REFERENCES users(user_id),
    CHECK (end_odometer_km IS NULL OR end_odometer_km >= start_odometer_km)
);

CREATE TABLE fuel_stations (
    station_id SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    address    VARCHAR(200)
);

CREATE TABLE fuel_records (
    fuel_id         BIGSERIAL PRIMARY KEY,
    vehicle_id      BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
    driver_id       BIGINT REFERENCES drivers(driver_id),
    station_id      INT REFERENCES fuel_stations(station_id),
    fuel_type_id    INT NOT NULL REFERENCES fuel_types(fuel_type_id),
    fueled_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    liters          NUMERIC(7,2) NOT NULL CHECK (liters > 0),
    price_per_liter NUMERIC(8,2) NOT NULL CHECK (price_per_liter > 0),
    total_cost      NUMERIC(12,2) GENERATED ALWAYS AS (liters * price_per_liter) STORED,
    odometer_km     NUMERIC(10,1),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by      BIGINT REFERENCES users(user_id)
);

CREATE TABLE service_stations (
    service_id SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    address    VARCHAR(200),
    phone      VARCHAR(20),
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    deleted_by BIGINT REFERENCES users(user_id)
);

CREATE TABLE maintenance_types (
    type_id         SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL UNIQUE,
    interval_km     INT,
    interval_months INT
);

CREATE TABLE maintenance_orders (
    order_id    BIGSERIAL PRIMARY KEY,
    vehicle_id  BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
    type_id     INT NOT NULL REFERENCES maintenance_types(type_id),
    service_id  INT REFERENCES service_stations(service_id),
    opened_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at   TIMESTAMPTZ,
    odometer_km NUMERIC(10,1),
    cost        NUMERIC(12,2) CHECK (cost >= 0),
    status      VARCHAR(12) NOT NULL DEFAULT 'IN_PROGRESS'
                CHECK (status IN ('OPEN','IN_PROGRESS','COMPLETED','CANCELLED')),
    description TEXT,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  BIGINT REFERENCES users(user_id)
);

CREATE TABLE insurance_companies (
    company_id SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL UNIQUE,
    phone      VARCHAR(20)
);

CREATE TABLE insurance_policies (
    policy_id     BIGSERIAL PRIMARY KEY,
    vehicle_id    BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
    company_id    INT NOT NULL REFERENCES insurance_companies(company_id),
    policy_number VARCHAR(40) NOT NULL,
    policy_type   VARCHAR(10) NOT NULL CHECK (policy_type IN ('OSAGO','KASKO')),
    valid_from    DATE NOT NULL,
    valid_to      DATE NOT NULL,
    premium       NUMERIC(12,2) NOT NULL CHECK (premium >= 0),
    is_deleted    BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at    TIMESTAMPTZ,
    deleted_by    BIGINT REFERENCES users(user_id),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by    BIGINT REFERENCES users(user_id),
    CHECK (valid_to > valid_from)
);

CREATE TABLE fines (
    fine_id     BIGSERIAL PRIMARY KEY,
    vehicle_id  BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
    driver_id   BIGINT REFERENCES drivers(driver_id),
    trip_id     BIGINT REFERENCES trips(trip_id),
    fine_date   DATE NOT NULL,
    amount      NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    description VARCHAR(250),
    is_paid     BOOLEAN NOT NULL DEFAULT FALSE,
    paid_at     TIMESTAMPTZ
);

CREATE TABLE audit_log (
    log_id     BIGSERIAL PRIMARY KEY,
    table_name VARCHAR(60) NOT NULL,
    record_id  BIGINT NOT NULL,
    action     VARCHAR(10) NOT NULL,
    old_data   JSONB,
    new_data   JSONB,
    changed_by BIGINT REFERENCES users(user_id),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO roles(name, description) VALUES
 ('Admin','Адміністратор системи'),('Dispatcher','Диспетчер'),('Driver','Водій');

INSERT INTO users(role_id, login, password_hash, full_name, email)
VALUES (1, 'admin', 'CHANGE_ME_HASH', 'Адміністратор', 'admin@fleet.local');

INSERT INTO vehicle_statuses(code, name) VALUES
 ('AVAILABLE','Доступний'),('IN_TRIP','У рейсі'),
 ('MAINTENANCE','На обслуговуванні'),('DECOMMISSIONED','Списаний');

INSERT INTO fuel_types(name) VALUES ('Бензин A95'),('Дизель'),('Газ (LPG)'),('Електро');
INSERT INTO license_categories(code, description) VALUES
 ('B','Легкові авто'),('C','Вантажні авто'),('D','Автобуси');

INSERT INTO vehicle_brands(name) VALUES ('Toyota'),('Skoda'),('Volkswagen');
INSERT INTO vehicle_models(brand_id, name, body_type, seats, required_category_id) VALUES
 (1,'Camry','Седан',5,1),(2,'Octavia','Універсал',5,1),(3,'Transporter','Мікроавтобус',9,2);

INSERT INTO maintenance_types(name, interval_km, interval_months) VALUES
 ('Планове ТО',15000,12),('Заміна шин',NULL,6),('Ремонт',NULL,NULL);
INSERT INTO service_stations(name, address, phone) VALUES ('АвтоСервіс Київ','м. Київ, вул. Автопаркова, 1','+380441112233');
INSERT INTO fuel_stations(name, address) VALUES ('WOG','м. Київ, пр. Перемоги, 10');
INSERT INTO insurance_companies(name, phone) VALUES ('ТАС Страхування','0800500000');
