-- =========================================================
-- BiDi Database Project - PostgreSQL full implementation
-- =========================================================

DROP SCHEMA IF EXISTS bidi CASCADE;
CREATE SCHEMA bidi;
SET search_path TO bidi;

-- =========================================================
-- 01. SCHEMA
-- =========================================================

-- -------------------------
-- Core entities from ER model
-- -------------------------
CREATE TABLE location (
    lid         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    address     VARCHAR(200) NOT NULL,
    country     VARCHAR(100) NOT NULL,
    CONSTRAINT uq_location UNIQUE (address, country),
    CONSTRAINT chk_location_country CHECK (char_length(trim(country)) >= 2)
);

CREATE TABLE department (
    dep_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         VARCHAR(100) NOT NULL UNIQUE,
    lid          INTEGER NOT NULL,
    CONSTRAINT fk_department_location
        FOREIGN KEY (lid) REFERENCES location(lid)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

CREATE TABLE customer (
    cid          INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         VARCHAR(150) NOT NULL,
    email        VARCHAR(150) NOT NULL UNIQUE,
    lid          INTEGER NOT NULL,
    CONSTRAINT chk_customer_email CHECK (position('@' in email) > 1),
    CONSTRAINT fk_customer_location
        FOREIGN KEY (lid) REFERENCES location(lid)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

CREATE TABLE project (
    pr_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         VARCHAR(150) NOT NULL UNIQUE,
    budget       NUMERIC(12,2) NOT NULL,
    CONSTRAINT chk_project_budget CHECK (budget > 0)
);

CREATE TABLE employee (
    emp_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email        VARCHAR(150) NOT NULL UNIQUE,
    name         VARCHAR(150) NOT NULL,
    dep_id       INTEGER NOT NULL,
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
    name         VARCHAR(100) NOT NULL UNIQUE
);

-- -------------------------
-- Associative tables for M:N relationships
-- -------------------------

CREATE TABLE commissions (
    pr_id         INTEGER PRIMARY KEY,
    cid           INTEGER NOT NULL,
    start_date    DATE NOT NULL DEFAULT CURRENT_DATE,
    deadline      DATE NOT NULL,
    CONSTRAINT fk_commissions_project
        FOREIGN KEY (pr_id) REFERENCES project(pr_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_commissions_customer
        FOREIGN KEY (cid) REFERENCES customer(cid)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

-- Works (Project - Employee)
CREATE TABLE works (
    pr_id         INTEGER NOT NULL,
    emp_id        INTEGER NOT NULL,
    started       DATE NOT NULL DEFAULT CURRENT_DATE,
    PRIMARY KEY (pr_id, emp_id),
    CONSTRAINT fk_works_project
        FOREIGN KEY (pr_id) REFERENCES project(pr_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_works_employee
        FOREIGN KEY (emp_id) REFERENCES employee(emp_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

-- Has (Employee - Role)
CREATE TABLE has_role (
    emp_id        INTEGER NOT NULL,
    role_id       INTEGER NOT NULL,
    description   TEXT NOT NULL DEFAULT 'General responsibility',
    PRIMARY KEY (emp_id, role_id),
    CONSTRAINT fk_has_role_employee
        FOREIGN KEY (emp_id) REFERENCES employee(emp_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_has_role_role
        FOREIGN KEY (role_id) REFERENCES role(role_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

-- PartOf (UserGroup - Employee)
CREATE TABLE part_of (
    gr_id         INTEGER NOT NULL,
    emp_id        INTEGER NOT NULL,
    PRIMARY KEY (gr_id, emp_id),
    CONSTRAINT fk_part_of_group
        FOREIGN KEY (gr_id) REFERENCES user_group(gr_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_part_of_employee
        FOREIGN KEY (emp_id) REFERENCES employee(emp_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
);

-- Support table for trigger audit trail
CREATE TABLE project_budget_audit (
    audit_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pr_id         INTEGER NOT NULL,
    old_budget    NUMERIC(12,2) NOT NULL,
    new_budget    NUMERIC(12,2) NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    changed_by    TEXT NOT NULL DEFAULT CURRENT_USER,
    CONSTRAINT fk_budget_audit_project
        FOREIGN KEY (pr_id) REFERENCES project(pr_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
);

-- =========================================================
-- 02. TRIGGERS
-- =========================================================

-- Trigger 1: deadline must be after commission start date
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

-- Trigger 2: work assignment date must fall within project commission period
CREATE OR REPLACE FUNCTION fn_validate_work_started_date()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_date DATE;
    v_deadline   DATE;
BEGIN
    SELECT start_date, deadline
      INTO v_start_date, v_deadline
      FROM commissions
     WHERE pr_id = NEW.pr_id;

    IF v_start_date IS NULL OR v_deadline IS NULL THEN
        RAISE EXCEPTION 'A project must have a commission record before employees can be assigned';
    END IF;

    IF NEW.started < v_start_date THEN
        RAISE EXCEPTION 'Work start date (%) cannot be before commission start date (%)', NEW.started, v_start_date;
    END IF;

    IF NEW.started > v_deadline THEN
        RAISE EXCEPTION 'Work start date (%) cannot be after project deadline (%)', NEW.started, v_deadline;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_work_started_date
BEFORE INSERT OR UPDATE ON works
FOR EACH ROW
EXECUTE FUNCTION fn_validate_work_started_date();

-- Trigger 3: audit project budget changes
CREATE OR REPLACE FUNCTION fn_audit_project_budget_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.budget <> OLD.budget THEN
        INSERT INTO project_budget_audit (pr_id, old_budget, new_budget)
        VALUES (OLD.pr_id, OLD.budget, NEW.budget);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_project_budget_change
AFTER UPDATE OF budget ON project
FOR EACH ROW
EXECUTE FUNCTION fn_audit_project_budget_change();

-- =========================================================
-- 03. VIEW
-- =========================================================

CREATE OR REPLACE VIEW vw_project_overview AS
SELECT
    p.pr_id,
    p.name AS project_name,
    p.budget,
    c.name AS customer_name,
    c.email AS customer_email,
    l.address,
    l.country,
    co.start_date,
    co.deadline
FROM project p
JOIN commissions co ON co.pr_id = p.pr_id
JOIN customer c ON c.cid = co.cid
JOIN location l ON l.lid = c.lid;

-- =========================================================
-- 04. INDEXES (useful optional improvement)
-- =========================================================

CREATE INDEX idx_customer_lid ON customer(lid);
CREATE INDEX idx_department_lid ON department(lid);
CREATE INDEX idx_employee_dep_id ON employee(dep_id);
CREATE INDEX idx_commissions_cid ON commissions(cid);
CREATE INDEX idx_works_emp_id ON works(emp_id);
CREATE INDEX idx_has_role_role_id ON has_role(role_id);
CREATE INDEX idx_part_of_emp_id ON part_of(emp_id);

-- =========================================================
-- 05. SEED DATA
-- =========================================================

INSERT INTO location (address, country) VALUES
('Mannerheimintie 12, Helsinki', 'Finland'),
('Kauppakatu 5, Lahti', 'Finland'),
('Tekniikantie 3, Espoo', 'Finland');

INSERT INTO department (name, lid) VALUES
('Software', 1),
('Data', 2),
('ICT', 3),
('HR', 2),
('Customer Support', 1);

INSERT INTO customer (name, email, lid) VALUES
('NordCare Oy', 'contact@nordcare.fi', 1),
('MedPulse Ltd', 'info@medpulse.fi', 2),
('ClinicFlow Group', 'projects@clinicflow.fi', 3);

INSERT INTO project (name, budget) VALUES
('Patient Portal Modernization', 250000.00),
('Clinical Data Warehouse', 420000.00),
('Support Ticket Automation', 95000.00),
('Remote Monitoring Dashboard', 180000.00);

INSERT INTO commissions (pr_id, cid, start_date, deadline) VALUES
(1, 1, DATE '2026-01-10', DATE '2026-09-30'),
(2, 2, DATE '2026-02-01', DATE '2026-12-15'),
(3, 3, DATE '2026-03-01', DATE '2026-07-31'),
(4, 1, DATE '2026-01-20', DATE '2026-10-20');

INSERT INTO employee (email, name, dep_id) VALUES
('alice.virtanen@bidi.fi', 'Alice Virtanen', 1),
('mikko.koskinen@bidi.fi', 'Mikko Koskinen', 1),
('laura.lahti@bidi.fi', 'Laura Lahti', 2),
('joni.niemi@bidi.fi', 'Joni Niemi', 3),
('sofia.heikkila@bidi.fi', 'Sofia Heikkila', 5),
('emma.salonen@bidi.fi', 'Emma Salonen', 4);

INSERT INTO role (name) VALUES
('Developer'),
('Data Engineer'),
('System Administrator'),
('Project Manager'),
('Support Specialist');

INSERT INTO user_group (name) VALUES
('Managers'),
('Developers'),
('Support Team'),
('Customer Liaison');

INSERT INTO has_role (emp_id, role_id, description) VALUES
(1, 1, 'Backend development for patient systems'),
(1, 4, 'Coordinates project delivery and reporting'),
(2, 1, 'API and integration development'),
(3, 2, 'ETL and reporting pipelines'),
(4, 3, 'Maintains infrastructure and secure access'),
(5, 5, 'Handles support escalation and response'),
(6, 4, 'Leads internal rollout work');

INSERT INTO part_of (gr_id, emp_id) VALUES
(1, 1),
(1, 6),
(2, 1),
(2, 2),
(3, 5),
(4, 5);

INSERT INTO works (pr_id, emp_id, started) VALUES
(1, 1, DATE '2026-01-15'),
(1, 2, DATE '2026-01-18'),
(1, 5, DATE '2026-02-03'),
(2, 3, DATE '2026-02-05'),
(2, 4, DATE '2026-02-05'),
(3, 5, DATE '2026-03-05'),
(4, 1, DATE '2026-01-25'),
(4, 6, DATE '2026-02-10');

-- =========================================================
-- 06. ACCESS CONTROL
-- =========================================================

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

GRANT USAGE ON SCHEMA bidi TO bidi_admin_role, bidi_manager_role, bidi_customer_role;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA bidi TO bidi_admin_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA bidi TO bidi_admin_role;

GRANT SELECT ON ALL TABLES IN SCHEMA bidi TO bidi_manager_role;
GRANT INSERT, UPDATE, DELETE ON project, commissions, works, has_role, part_of TO bidi_manager_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA bidi TO bidi_manager_role;

REVOKE ALL ON ALL TABLES IN SCHEMA bidi FROM bidi_customer_role;
GRANT SELECT ON vw_project_overview TO bidi_customer_role;

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

-- Permission check matrix for demo/report
SELECT
    r.role_name,
    has_table_privilege(r.role_name, 'bidi.vw_project_overview', 'SELECT') AS can_view_overview,
    has_table_privilege(r.role_name, 'bidi.employee', 'SELECT') AS can_read_employee,
    has_table_privilege(r.role_name, 'bidi.project', 'INSERT') AS can_insert_project,
    has_table_privilege(r.role_name, 'bidi.customer', 'DELETE') AS can_delete_customer
FROM (VALUES
    ('bidi_customer_role'::text),
    ('bidi_manager_role'::text),
    ('bidi_admin_role'::text)
) AS r(role_name);

-- Authorized action: customer can read the view
BEGIN;
SET LOCAL ROLE bidi_customer_role;
SELECT pr_id, project_name, customer_name, deadline
FROM bidi.vw_project_overview
ORDER BY pr_id;
ROLLBACK;

-- Authorized action: manager can update project budget
BEGIN;
SET LOCAL ROLE bidi_manager_role;
UPDATE bidi.project
SET budget = budget + 1000
WHERE pr_id = 3;
ROLLBACK;

-- Unauthorized access confirmation for demo
DO $$
BEGIN
    IF NOT has_table_privilege('bidi_customer_role', 'bidi.employee', 'SELECT') THEN
        RAISE NOTICE 'VERIFIED: bidi_customer_role denied SELECT on employee';
    END IF;

    IF NOT has_table_privilege('bidi_customer_role', 'bidi.project', 'INSERT') THEN
        RAISE NOTICE 'VERIFIED: bidi_customer_role denied INSERT on project';
    END IF;

    IF NOT has_table_privilege('bidi_manager_role', 'bidi.customer', 'DELETE') THEN
        RAISE NOTICE 'VERIFIED: bidi_manager_role denied DELETE on customer';
    END IF;
END $$;

-- =========================================================
-- 07. REQUIRED QUERIES
-- =========================================================

-- -------------------------
-- 2 simple SELECT queries
-- -------------------------
SELECT pr_id, name, budget
FROM project
ORDER BY budget DESC;

SELECT emp_id, name, email
FROM employee
ORDER BY name;

-- -------------------------
-- 3 JOIN queries (3 or more tables)
-- -------------------------

-- JOIN 1: project, employee, department
SELECT
    p.name AS project_name,
    e.name AS employee_name,
    d.name AS department_name,
    w.started
FROM works w
JOIN project p ON p.pr_id = w.pr_id
JOIN employee e ON e.emp_id = w.emp_id
JOIN department d ON d.dep_id = e.dep_id
ORDER BY p.name, e.name;

-- JOIN 2: project, customer, location, commissions
SELECT
    p.name AS project_name,
    c.name AS customer_name,
    l.address,
    l.country,
    co.start_date,
    co.deadline
FROM project p
JOIN commissions co ON co.pr_id = p.pr_id
JOIN customer c ON c.cid = co.cid
JOIN location l ON l.lid = c.lid
ORDER BY co.deadline;

-- JOIN 3: employee, role, group membership, user group
SELECT
    e.name AS employee_name,
    r.name AS role_name,
    ug.name AS user_group_name,
    hr.description
FROM employee e
JOIN has_role hr ON hr.emp_id = e.emp_id
JOIN role r ON r.role_id = hr.role_id
LEFT JOIN part_of po ON po.emp_id = e.emp_id
LEFT JOIN user_group ug ON ug.gr_id = po.gr_id
ORDER BY e.name, r.name;

-- -------------------------
-- 2 aggregation queries
-- -------------------------

SELECT
    d.name AS department_name,
    COUNT(e.emp_id) AS employee_count
FROM department d
LEFT JOIN employee e ON e.dep_id = d.dep_id
GROUP BY d.name
ORDER BY employee_count DESC, d.name;

SELECT
    c.name AS customer_name,
    COUNT(co.pr_id) AS project_count,
    SUM(p.budget) AS total_budget
FROM customer c
JOIN commissions co ON co.cid = c.cid
JOIN project p ON p.pr_id = co.pr_id
GROUP BY c.name
HAVING COUNT(co.pr_id) >= 1
ORDER BY total_budget DESC;

-- -------------------------
-- View usage
-- -------------------------
SELECT *
FROM vw_project_overview
ORDER BY pr_id;

-- -------------------------
-- INSERT, UPDATE, DELETE examples
-- -------------------------

-- INSERT example
INSERT INTO user_group (name)
VALUES ('Analytics Review');

INSERT INTO part_of (gr_id, emp_id)
VALUES ((SELECT gr_id FROM user_group WHERE name = 'Analytics Review'), 1);

-- UPDATE example
UPDATE project
SET budget = budget + 15000
WHERE pr_id = 1;

SELECT *
FROM project_budget_audit
ORDER BY changed_at DESC;

-- DELETE example
DELETE FROM part_of
WHERE gr_id = (SELECT gr_id FROM user_group WHERE name = 'Analytics Review')
  AND emp_id = 1;

DELETE FROM user_group
WHERE name = 'Analytics Review';

-- =========================================================
-- 08. CONSTRAINT AND TRIGGER FAILURE DEMOS
-- =========================================================

-- CHECK failure: invalid budget
DO $$
BEGIN
    INSERT INTO project (name, budget)
    VALUES ('Invalid Budget Project', -1000);
    RAISE NOTICE 'TEST 1 FAILED - invalid budget insert should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 1 PASSED - rejected as expected: %', SQLERRM;
END $$;

-- CHECK failure: invalid customer email
DO $$
BEGIN
    INSERT INTO customer (name, email, lid)
    VALUES ('Broken Customer', 'not-an-email', 1);
    RAISE NOTICE 'TEST 2 FAILED - invalid email insert should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 2 PASSED - rejected as expected: %', SQLERRM;
END $$;

-- UNIQUE failure: duplicate employee email
DO $$
BEGIN
    INSERT INTO employee (email, name, dep_id)
    VALUES ('alice.virtanen@bidi.fi', 'Duplicate Alice', 1);
    RAISE NOTICE 'TEST 3 FAILED - duplicate email insert should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 3 PASSED - rejected as expected: %', SQLERRM;
END $$;

-- FK failure: missing department
DO $$
BEGIN
    INSERT INTO employee (email, name, dep_id)
    VALUES ('ghost@bidi.fi', 'Ghost Employee', 999);
    RAISE NOTICE 'TEST 4 FAILED - missing department insert should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 4 PASSED - rejected as expected: %', SQLERRM;
END $$;

-- Trigger failure: deadline before start date
DO $$
BEGIN
    INSERT INTO project (name, budget)
    VALUES ('Commission Date Test', 10000);

    INSERT INTO commissions (pr_id, cid, start_date, deadline)
    VALUES (
        (SELECT pr_id FROM project WHERE name = 'Commission Date Test'),
        1,
        DATE '2026-06-10',
        DATE '2026-06-05'
    );

    RAISE NOTICE 'TEST 5 FAILED - invalid commission dates should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 5 PASSED - rejected as expected: %', SQLERRM;
END $$;

-- Trigger failure: employee assigned after deadline
DO $$
BEGIN
    INSERT INTO works (pr_id, emp_id, started)
    VALUES (1, 3, DATE '2027-01-01');
    RAISE NOTICE 'TEST 6 FAILED - invalid work start should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 6 PASSED - rejected as expected: %', SQLERRM;
END $$;
