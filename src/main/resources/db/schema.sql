CREATE SCHEMA IF NOT EXISTS rxnorm_lab;

CREATE TABLE IF NOT EXISTS rxnorm_lab.release (
  release text PRIMARY KEY,
  scope text NOT NULL,
  sha256_json text NOT NULL,
  identity text NOT NULL,
  state text NOT NULL CHECK (state IN ('loading', 'ready')),
  concept_count bigint NOT NULL DEFAULT 0,
  description_count bigint NOT NULL DEFAULT 0,
  relation_count bigint NOT NULL DEFAULT 0,
  conso_row_count bigint NOT NULL DEFAULT 0,
  rel_row_count bigint NOT NULL DEFAULT 0
);

-- All original RXNCONSO fields are text, including empty strings and identifiers.
-- No uniqueness is imposed on source rows: the downloaded records remain intact.
CREATE TABLE IF NOT EXISTS rxnorm_lab.rxnconso (
  release text NOT NULL REFERENCES rxnorm_lab.release(release),
  rxcui text NOT NULL, lat text NOT NULL, ts text NOT NULL, lui text NOT NULL,
  stt text NOT NULL, sui text NOT NULL, ispref text NOT NULL, rxaui text NOT NULL,
  saui text NOT NULL, scui text NOT NULL, sdui text NOT NULL, sab text NOT NULL,
  tty text NOT NULL, code text NOT NULL, str text NOT NULL, srl text NOT NULL,
  suppress text NOT NULL, cvf text NOT NULL
);

-- RXNREL uses RG before DIR in the current official RRF format.
CREATE TABLE IF NOT EXISTS rxnorm_lab.rxnrel (
  release text NOT NULL REFERENCES rxnorm_lab.release(release),
  rxcui1 text NOT NULL, rxaui1 text NOT NULL, stype1 text NOT NULL, rel text NOT NULL,
  rxcui2 text NOT NULL, rxaui2 text NOT NULL, stype2 text NOT NULL, rela text NOT NULL,
  rui text NOT NULL, srui text NOT NULL, sab text NOT NULL, sl text NOT NULL,
  rg text NOT NULL, dir text NOT NULL, suppress text NOT NULL, cvf text NOT NULL
);

-- Small derived query tables retain a link to the original release and atom.
CREATE TABLE IF NOT EXISTS rxnorm_lab.rx_concept (
  release text NOT NULL REFERENCES rxnorm_lab.release(release),
  rxcui text NOT NULL, tty text NOT NULL, display text NOT NULL,
  PRIMARY KEY (release,rxcui)
);

CREATE TABLE IF NOT EXISTS rxnorm_lab.lexical_name (
  release text NOT NULL,
  rxcui text NOT NULL, rxaui text NOT NULL, text text NOT NULL,
  normalized text NOT NULL, tty text NOT NULL, sab text NOT NULL,
  PRIMARY KEY (release,rxaui),
  FOREIGN KEY (release,rxcui) REFERENCES rxnorm_lab.rx_concept(release,rxcui)
);

-- Long source names must not exceed the B-tree entry-size limit.
-- Lookup checks full normalized equality after this fixed-size digest filter.
DROP INDEX IF EXISTS rxnorm_lab.lexical_name_lookup;
CREATE INDEX IF NOT EXISTS lexical_name_lookup_md5
  ON rxnorm_lab.lexical_name(release,md5(normalized));

CREATE INDEX IF NOT EXISTS rxnrel_outgoing
  ON rxnorm_lab.rxnrel(release,rxcui2)
  WHERE sab='RXNORM' AND suppress IN ('','N')
    AND stype1='CUI' AND stype2='CUI' AND rela<>'';

CREATE TABLE IF NOT EXISTS rxnorm_lab.binding (
  run_id text PRIMARY KEY,
  release text NOT NULL REFERENCES rxnorm_lab.release(release),
  input_json text NOT NULL,
  output_json text NOT NULL
);
