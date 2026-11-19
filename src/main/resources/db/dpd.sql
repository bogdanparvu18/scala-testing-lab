CREATE SCHEMA IF NOT EXISTS health_canada_dpd;

CREATE TABLE IF NOT EXISTS health_canada_dpd.product (
  drug_code integer PRIMARY KEY CHECK (drug_code > 0),
  product_categorization text NOT NULL, class_name text NOT NULL CHECK (class_name = 'Human'),
  din text UNIQUE NOT NULL CHECK (din ~ '^[0-9]{8}$'), brand_name text NOT NULL CHECK (brand_name <> ''),
  descriptor text NOT NULL, pediatric_flag text NOT NULL, accession_number text NOT NULL,
  number_of_ais text NOT NULL, last_update_date date, ai_group_no text NOT NULL,
  class_name_f text NOT NULL, brand_name_f text NOT NULL, descriptor_f text NOT NULL
);

-- Keep the source's repeated child rows and original units, including the denominator in concentrations.
CREATE TABLE IF NOT EXISTS health_canada_dpd.ingredient (
  drug_code integer NOT NULL REFERENCES health_canada_dpd.product(drug_code),
  ingredient_code text NOT NULL, ingredient text NOT NULL CHECK (ingredient <> ''), ingredient_supplied_ind text NOT NULL,
  strength text NOT NULL, strength_unit text NOT NULL, strength_type text NOT NULL,
  dosage_value text NOT NULL, base text NOT NULL, dosage_unit text NOT NULL, notes text NOT NULL,
  ingredient_f text NOT NULL, strength_unit_f text NOT NULL, strength_type_f text NOT NULL, dosage_unit_f text NOT NULL
);
CREATE INDEX IF NOT EXISTS dpd_ingredient_product ON health_canada_dpd.ingredient(drug_code);

CREATE TABLE IF NOT EXISTS health_canada_dpd.form (
  drug_code integer NOT NULL REFERENCES health_canada_dpd.product(drug_code),
  form_code text NOT NULL, form text NOT NULL CHECK (form <> ''), form_f text NOT NULL
);
CREATE INDEX IF NOT EXISTS dpd_form_product ON health_canada_dpd.form(drug_code);

CREATE TABLE IF NOT EXISTS health_canada_dpd.route (
  drug_code integer NOT NULL REFERENCES health_canada_dpd.product(drug_code),
  route_code text NOT NULL, route text NOT NULL CHECK (route <> ''), route_f text NOT NULL
);
CREATE INDEX IF NOT EXISTS dpd_route_product ON health_canada_dpd.route(drug_code);

CREATE TABLE IF NOT EXISTS health_canada_dpd.status (
  drug_code integer NOT NULL REFERENCES health_canada_dpd.product(drug_code),
  current_status_flag text NOT NULL CHECK (current_status_flag IN ('Y','N')),
  status text NOT NULL CHECK (status <> ''), history_date date NOT NULL, status_f text NOT NULL,
  lot_number text NOT NULL, expiration_date date
);
CREATE INDEX IF NOT EXISTS dpd_status_product ON health_canada_dpd.status(drug_code);

CREATE TABLE IF NOT EXISTS health_canada_dpd.snapshot (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'), source text NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  products bigint NOT NULL, ingredients bigint NOT NULL, forms bigint NOT NULL,
  routes bigint NOT NULL, statuses bigint NOT NULL
);
