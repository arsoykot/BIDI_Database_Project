-- ===== START 01_schema.sql =====


-- =========================================================
-- 01_schema.sql
-- BiDi Database Project - PostgreSQL schema
-- =========================================================

DROP SCHEMA IF EXISTS bidi CASCADE;
CREATE SCHEMA bidi;
SET search_path TO bidi;

-- =========================
-- Core entities
-- =========================
CREATE TABLE location (
    lid         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    address     VARCHAR(200) NOT NULL,
    city        VARCHAR(100) NOT NULL,
    country     VARCHAR(100) NOT NULL,
    CONSTRAINT uq_location UNIQUE(address, city, country),
    CONSTRAINT chk_location_country CHECK (char_length(trim(country)) >= 2)
);

CREATE TABLE department (
    dep_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lid         INTEGER NOT NULL,
    name        VARCHAR(100) NOT NULL UNIQUE,
    CONSTRAINT fk_department_location
        FOREIGN KEY (lid) REFERENCES location(lid)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

CREATE TABLE customer (
    cid         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lid         INTEGER NOT NULL,
    name        VARCHAR(150) NOT NULL,
    email       VARCHAR(150) NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_customer_email UNIQUE(email),
    CONSTRAINT chk_customer_email CHECK (position('@' in email) > 1),
    CONSTRAINT fk_customer_location
        FOREIGN KEY (lid) REFERENCES location(lid)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

CREATE TABLE project (
    pr_id           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(150) NOT NULL UNIQUE,
    budget          NUMERIC(12,2) NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'PLANNED',
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_project_budget CHECK (budget > 0),
    CONSTRAINT chk_project_status CHECK (status IN ('PLANNED','ACTIVE','ON_HOLD','COMPLETED','CANCELLED'))
);

CREATE TABLE employee (
    emp_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dep_id       INTEGER NOT NULL,
    email        VARCHAR(150) NOT NULL,
    name         VARCHAR(150) NOT NULL,
    hired_on     DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT uq_employee_email UNIQUE(email),
    CONSTRAINT chk_employee_email CHECK (position('@' in email) > 1),
    CONSTRAINT fk_employee_department
        FOREIGN KEY (dep_id) REFERENCES department(dep_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

CREATE TABLE role (
    role_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE user_group (
    gr_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         VARCHAR(100) NOT NULL UNIQUE,
    visibility   VARCHAR(20) NOT NULL DEFAULT 'INTERNAL',
    CONSTRAINT chk_group_visibility CHECK (visibility IN ('INTERNAL','CUSTOMER','RESTRICTED'))
);

-- =========================
-- Relationship tables
-- =========================

-- One project belongs to exactly one customer.
CREATE TABLE commissions (
    pr_id        INTEGER PRIMARY KEY,
    cid          INTEGER NOT NULL,
    start_date   DATE NOT NULL,
    deadline     DATE NOT NULL,
    CONSTRAINT fk_commission_project
        FOREIGN KEY (pr_id) REFERENCES project(pr_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_commission_customer
        FOREIGN KEY (cid) REFERENCES customer(cid)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

CREATE TABLE works_on (
    pr_id            INTEGER NOT NULL,
    emp_id           INTEGER NOT NULL,
    started          DATE NOT NULL DEFAULT CURRENT_DATE,
    allocation_pct   NUMERIC(5,2) NOT NULL DEFAULT 100.00,
    PRIMARY KEY (pr_id, emp_id),
    CONSTRAINT chk_allocation_pct CHECK (allocation_pct > 0 AND allocation_pct <= 100),
    CONSTRAINT fk_works_project
        FOREIGN KEY (pr_id) REFERENCES project(pr_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_works_employee
        FOREIGN KEY (emp_id) REFERENCES employee(emp_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

CREATE TABLE employee_role (
    emp_id        INTEGER NOT NULL,
    role_id       INTEGER NOT NULL,
    description   TEXT NOT NULL,
    assigned_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (emp_id, role_id),
    CONSTRAINT fk_emp_role_employee
        FOREIGN KEY (emp_id) REFERENCES employee(emp_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_emp_role_role
        FOREIGN KEY (role_id) REFERENCES role(role_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

CREATE TABLE group_membership (
    gr_id        INTEGER NOT NULL,
    emp_id       INTEGER NOT NULL,
    joined_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (gr_id, emp_id),
    CONSTRAINT fk_group_membership_group
        FOREIGN KEY (gr_id) REFERENCES user_group(gr_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_group_membership_employee
        FOREIGN KEY (emp_id) REFERENCES employee(emp_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
);

-- Audit table used by triggers
CREATE TABLE project_budget_audit (
    audit_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pr_id           INTEGER NOT NULL,
    old_budget      NUMERIC(12,2) NOT NULL,
    new_budget      NUMERIC(12,2) NOT NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    changed_by      TEXT NOT NULL DEFAULT CURRENT_USER,
    CONSTRAINT fk_budget_audit_project
        FOREIGN KEY (pr_id) REFERENCES project(pr_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
);


-- ===== END 01_schema.sql =====


-- ===== START 02_triggers_views_indexes.sql =====


-- =========================================================
-- 02_triggers_views_indexes.sql
-- =========================================================
SET search_path TO bidi;

-- ---------------------------------------------------------
-- Trigger 1: validate commission dates
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_validate_commission_dates()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.deadline <= NEW.start_date THEN
        RAISE EXCEPTION 'Deadline (%) must be later than start date (%)', NEW.deadline, NEW.start_date;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_commission_dates
BEFORE INSERT OR UPDATE ON commissions
FOR EACH ROW
EXECUTE FUNCTION fn_validate_commission_dates();

-- ---------------------------------------------------------
-- Trigger 2: block work assignments after project deadline
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_check_project_deadline_before_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_deadline DATE;
BEGIN
    SELECT deadline
      INTO v_deadline
      FROM commissions
     WHERE pr_id = NEW.pr_id;

    IF v_deadline IS NULL THEN
        RAISE EXCEPTION 'Cannot assign employee to project % before its commission record exists', NEW.pr_id;
    END IF;

    IF NEW.started > v_deadline THEN
        RAISE EXCEPTION 'Cannot assign employee after project deadline (%)', v_deadline;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_project_deadline_before_assignment
BEFORE INSERT OR UPDATE ON works_on
FOR EACH ROW
EXECUTE FUNCTION fn_check_project_deadline_before_assignment();

-- ---------------------------------------------------------
-- Trigger 3: audit project budget changes
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_project_budget_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.budget <> OLD.budget THEN
        INSERT INTO project_budget_audit(pr_id, old_budget, new_budget)
        VALUES (OLD.pr_id, OLD.budget, NEW.budget);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_project_budget_change
AFTER UPDATE OF budget ON project
FOR EACH ROW
EXECUTE FUNCTION fn_audit_project_budget_change();

-- ---------------------------------------------------------
-- Trigger 4 (bonus): auto-add project managers to Managers group
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_auto_add_manager_group()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_manager_role_id INTEGER;
    v_group_id INTEGER;
BEGIN
    SELECT role_id INTO v_manager_role_id
    FROM role
    WHERE lower(name) = 'project manager';

    SELECT gr_id INTO v_group_id
    FROM user_group
    WHERE lower(name) = 'managers';

    IF v_manager_role_id IS NOT NULL
       AND v_group_id IS NOT NULL
       AND NEW.role_id = v_manager_role_id THEN
        INSERT INTO group_membership(gr_id, emp_id)
        VALUES (v_group_id, NEW.emp_id)
        ON CONFLICT (gr_id, emp_id) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_auto_add_manager_group
AFTER INSERT ON employee_role
FOR EACH ROW
EXECUTE FUNCTION fn_auto_add_manager_group();

-- ---------------------------------------------------------
-- View required by project brief
-- ---------------------------------------------------------
CREATE OR REPLACE VIEW vw_project_overview AS
SELECT
    p.pr_id,
    p.name AS project_name,
    p.status,
    p.budget,
    c.name AS customer_name,
    c.email AS customer_email,
    co.start_date,
    co.deadline,
    d.name AS department_name,
    l.city AS delivery_city,
    l.country
FROM project p
JOIN commissions co ON co.pr_id = p.pr_id
JOIN customer c ON c.cid = co.cid
LEFT JOIN works_on w ON w.pr_id = p.pr_id
LEFT JOIN employee e ON e.emp_id = w.emp_id
LEFT JOIN department d ON d.dep_id = e.dep_id
LEFT JOIN location l ON l.lid = c.lid;

-- ---------------------------------------------------------
-- Bonus indexes
-- ---------------------------------------------------------
CREATE INDEX idx_customer_email_lower
    ON customer (lower(email));

CREATE INDEX idx_employee_email_lower
    ON employee (lower(email));

CREATE INDEX idx_works_on_emp_id
    ON works_on (emp_id);

CREATE INDEX idx_commissions_cid_deadline
    ON commissions (cid, deadline);

CREATE INDEX idx_project_status
    ON project (status);


-- ===== END 02_triggers_views_indexes.sql =====


-- ===== START 03_seed_data.sql =====


-- =========================================================
-- 03_seed_data.sql
-- =========================================================
SET search_path TO bidi;

INSERT INTO location(address, city, country) VALUES
('Mannerheimintie 12', 'Helsinki', 'Finland'),
('Kauppakatu 5', 'Lahti', 'Finland'),
('Tekniikantie 3', 'Espoo', 'Finland'),
('Asemakatu 10', 'Tampere', 'Finland');

INSERT INTO department(lid, name) VALUES
(1, 'Software'),
(2, 'Data'),
(3, 'ICT'),
(2, 'HR'),
(4, 'Customer Support');

INSERT INTO customer(lid, name, email) VALUES
(1, 'NordCare Oy', 'contact@nordcare.fi'),
(4, 'MedPulse Ltd', 'info@medpulse.fi'),
(3, 'ClinicFlow Group', 'projects@clinicflow.fi');

INSERT INTO project(name, budget, status) VALUES
('Patient Portal Modernization', 250000.00, 'ACTIVE'),
('Clinical Data Warehouse', 420000.00, 'ACTIVE'),
('Support Ticket Automation', 95000.00, 'PLANNED'),
('Remote Monitoring Dashboard', 180000.00, 'ON_HOLD');

INSERT INTO commissions(pr_id, cid, start_date, deadline) VALUES
(1, 1, DATE '2026-01-10', DATE '2026-09-30'),
(2, 2, DATE '2026-02-01', DATE '2026-12-15'),
(3, 3, DATE '2026-03-01', DATE '2026-07-31'),
(4, 1, DATE '2026-01-20', DATE '2026-10-20');

INSERT INTO employee(dep_id, email, name, hired_on) VALUES
(1, 'alice.virtanen@bidi.fi', 'Alice Virtanen', DATE '2022-08-15'),
(1, 'mikko.koskinen@bidi.fi', 'Mikko Koskinen', DATE '2021-03-10'),
(2, 'laura.lahti@bidi.fi', 'Laura Lahti', DATE '2023-01-09'),
(3, 'joni.niemi@bidi.fi', 'Joni Niemi', DATE '2020-11-01'),
(5, 'sofia.heikkila@bidi.fi', 'Sofia Heikkila', DATE '2024-04-22'),
(4, 'emma.salonen@bidi.fi', 'Emma Salonen', DATE '2023-06-01');

INSERT INTO role(name) VALUES
('Developer'),
('Data Engineer'),
('System Administrator'),
('Project Manager'),
('Support Specialist');

INSERT INTO user_group(name, visibility) VALUES
('Managers', 'RESTRICTED'),
('Developers', 'INTERNAL'),
('Support Team', 'INTERNAL'),
('Customer Liaison', 'CUSTOMER');

INSERT INTO employee_role(emp_id, role_id, description) VALUES
(1, 1, 'Backend development for patient-facing systems'),
(1, 4, 'Coordinates sprint delivery and client reporting'),
(2, 1, 'API and integration development'),
(3, 2, 'Owns ETL and reporting pipelines'),
(4, 3, 'Maintains infrastructure and secure access'),
(5, 5, 'Handles support escalation and response'),
(6, 4, 'Leads HR system rollout sub-project');

INSERT INTO group_membership(gr_id, emp_id) VALUES
(2, 1),
(2, 2),
(3, 5),
(4, 5);

INSERT INTO works_on(pr_id, emp_id, started, allocation_pct) VALUES
(1, 1, DATE '2026-01-15', 60.00),
(1, 2, DATE '2026-01-18', 40.00),
(1, 5, DATE '2026-02-03', 20.00),
(2, 3, DATE '2026-02-05', 80.00),
(2, 4, DATE '2026-02-05', 30.00),
(3, 5, DATE '2026-03-05', 50.00),
(4, 1, DATE '2026-01-25', 35.00),
(4, 6, DATE '2026-02-10', 45.00);


-- ===== END 03_seed_data.sql =====


-- ===== START 06_access_control.sql =====


-- =========================================================
-- 06_access_control.sql
-- =========================================================
SET search_path TO bidi;

-- Create application roles
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bidi_admin_role') THEN
        CREATE ROLE bidi_admin_role NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bidi_manager_role') THEN
        CREATE ROLE bidi_manager_role NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bidi_customer_role') THEN
        CREATE ROLE bidi_customer_role NOINHERIT;
    END IF;
END $$;

-- Schema usage
GRANT USAGE ON SCHEMA bidi TO bidi_admin_role, bidi_manager_role, bidi_customer_role;

-- Admin can do everything
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA bidi TO bidi_admin_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA bidi TO bidi_admin_role;

-- Manager can read everything and modify project staffing data
GRANT SELECT ON ALL TABLES IN SCHEMA bidi TO bidi_manager_role;
GRANT INSERT, UPDATE, DELETE ON project, commissions, works_on, employee_role, group_membership
TO bidi_manager_role;

-- Customer role can only read project overview view
REVOKE ALL ON ALL TABLES IN SCHEMA bidi FROM bidi_customer_role;
GRANT SELECT ON vw_project_overview TO bidi_customer_role;

-- Optional future-proof defaults
ALTER DEFAULT PRIVILEGES IN SCHEMA bidi
GRANT SELECT ON TABLES TO bidi_manager_role;

-- Create demo login users
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bidi_admin_user') THEN
        CREATE USER bidi_admin_user WITH PASSWORD 'Admin#2026';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bidi_manager_user') THEN
        CREATE USER bidi_manager_user WITH PASSWORD 'Manager#2026';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bidi_customer_user') THEN
        CREATE USER bidi_customer_user WITH PASSWORD 'Customer#2026';
    END IF;
END $$;

GRANT bidi_admin_role TO bidi_admin_user;
GRANT bidi_manager_role TO bidi_manager_user;
GRANT bidi_customer_role TO bidi_customer_user;

-- Example demo commands
-- SET ROLE bidi_customer_user;
-- SELECT * FROM bidi.vw_project_overview;             -- authorized
-- SELECT * FROM bidi.employee;                        -- unauthorized
--
-- SET ROLE bidi_manager_user;
-- UPDATE bidi.project SET status = 'ACTIVE' WHERE pr_id = 3; -- authorized
-- DELETE FROM bidi.customer WHERE cid = 1;                  -- unauthorized (no delete grant)


-- ===== END 06_access_control.sql =====


-- ===== START 04_queries_and_demo.sql =====


-- =========================================================
-- 04_queries_and_demo.sql
-- =========================================================
SET search_path TO bidi;

-- ---------------------------------------------------------
-- 1) Simple SELECT queries (2)
-- ---------------------------------------------------------
SELECT pr_id, name, budget, status
FROM project
ORDER BY budget DESC;

SELECT emp_id, name, email, hired_on
FROM employee
WHERE hired_on >= DATE '2023-01-01'
ORDER BY hired_on;

-- ---------------------------------------------------------
-- 2) JOIN queries using 3 or more tables (3)
-- ---------------------------------------------------------
-- Query A: employee allocations by project and department
SELECT
    p.name AS project_name,
    e.name AS employee_name,
    d.name AS department_name,
    w.allocation_pct
FROM works_on w
JOIN project p    ON p.pr_id = w.pr_id
JOIN employee e   ON e.emp_id = w.emp_id
JOIN department d ON d.dep_id = e.dep_id
ORDER BY p.name, e.name;

-- Query B: projects with customer and location
SELECT
    p.name AS project_name,
    c.name AS customer_name,
    l.city,
    l.country,
    co.deadline
FROM project p
JOIN commissions co ON co.pr_id = p.pr_id
JOIN customer c     ON c.cid = co.cid
JOIN location l     ON l.lid = c.lid
ORDER BY co.deadline;

-- Query C: employee roles and group memberships
SELECT
    e.name AS employee_name,
    r.name AS role_name,
    ug.name AS user_group_name,
    er.description
FROM employee e
JOIN employee_role er ON er.emp_id = e.emp_id
JOIN role r           ON r.role_id = er.role_id
LEFT JOIN group_membership gm ON gm.emp_id = e.emp_id
LEFT JOIN user_group ug       ON ug.gr_id = gm.gr_id
ORDER BY e.name, r.name;

-- ---------------------------------------------------------
-- 3) Aggregation queries (2)
-- ---------------------------------------------------------
-- Query D: employee count per department
SELECT
    d.name AS department_name,
    COUNT(e.emp_id) AS employee_count
FROM department d
LEFT JOIN employee e ON e.dep_id = d.dep_id
GROUP BY d.name
ORDER BY employee_count DESC, d.name;

-- Query E: total allocated effort per project, filtered with HAVING
SELECT
    p.name AS project_name,
    SUM(w.allocation_pct) AS total_allocation_pct
FROM project p
JOIN works_on w ON w.pr_id = p.pr_id
GROUP BY p.name
HAVING SUM(w.allocation_pct) >= 70
ORDER BY total_allocation_pct DESC;

-- ---------------------------------------------------------
-- 4) View demo
-- ---------------------------------------------------------
SELECT DISTINCT
    pr_id, project_name, status, customer_name, start_date, deadline, country
FROM vw_project_overview
ORDER BY pr_id;

-- ---------------------------------------------------------
-- 5) INSERT, UPDATE, DELETE examples
-- ---------------------------------------------------------
-- INSERT example
INSERT INTO user_group(name, visibility)
VALUES ('Analytics Review', 'INTERNAL');

-- UPDATE example
UPDATE project
SET budget = budget + 15000
WHERE pr_id = 1;

-- Check audit trail after update
SELECT *
FROM project_budget_audit
ORDER BY changed_at DESC;

-- DELETE example
DELETE FROM group_membership
WHERE gr_id = (SELECT gr_id FROM user_group WHERE name = 'Analytics Review')
  AND emp_id = 1;

DELETE FROM user_group
WHERE name = 'Analytics Review';


-- ===== END 04_queries_and_demo.sql =====


-- ===== START 05_constraint_and_trigger_failure_tests.sql =====


-- =========================================================
-- 05_constraint_and_trigger_failure_tests.sql
-- =========================================================
SET search_path TO bidi;

-- 1) CHECK constraint failure: invalid budget
-- Expected: rejected because budget must be > 0
INSERT INTO project(name, budget, status)
VALUES ('Invalid Budget Project', -1000, 'PLANNED');

-- 2) CHECK constraint failure: invalid status
-- Expected: rejected because status is limited to the allowed set
INSERT INTO project(name, budget, status)
VALUES ('Bad Status Project', 5000, 'RUNNING');

-- 3) UNIQUE constraint failure: duplicate employee email
-- Expected: rejected
INSERT INTO employee(dep_id, email, name)
VALUES (1, 'alice.virtanen@bidi.fi', 'Duplicate Alice');

-- 4) FK failure: missing department
-- Expected: rejected
INSERT INTO employee(dep_id, email, name)
VALUES (999, 'ghost@bidi.fi', 'Ghost Employee');

-- 5) Trigger failure: deadline earlier than start date
-- Expected: rejected by trg_validate_commission_dates
INSERT INTO project(name, budget, status)
VALUES ('Commission Date Test', 10000, 'PLANNED');

INSERT INTO commissions(pr_id, cid, start_date, deadline)
VALUES (
    (SELECT pr_id FROM project WHERE name = 'Commission Date Test'),
    1,
    DATE '2026-06-10',
    DATE '2026-06-05'
);

-- 6) Trigger failure: assignment after deadline
-- Expected: rejected by trg_check_project_deadline_before_assignment
INSERT INTO works_on(pr_id, emp_id, started, allocation_pct)
VALUES (1, 3, DATE '2027-01-01', 20.00);


-- ===== END 05_constraint_and_trigger_failure_tests.sql =====

