CREATE SCHEMA university_fees;

CREATE TABLE university_fees.students (
    student_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE university_fees.payments (
    payment_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INTEGER NOT NULL,
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL,
    CONSTRAINT fk_payment_student
        FOREIGN KEY (student_id)
        REFERENCES university_fees.students(student_id)
);

CREATE TABLE university_fees.payment_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id INTEGER NOT NULL,
    student_id INTEGER NOT NULL,
    amount NUMERIC(12,2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_audit_payment
        FOREIGN KEY (payment_id)
        REFERENCES university_fees.payments(payment_id),

    CONSTRAINT fk_audit_student
        FOREIGN KEY (student_id)
        REFERENCES university_fees.students(student_id)
);

CREATE TABLE university_fees.daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

--seed--
INSERT INTO university_fees.students
(student_number, full_name, fee_due)
VALUES
('20260001','John Banda',5000),
('20260002','Mary Phiri',6000),
('20260003','Peter Zulu',4000);

--B--
CREATE OR REPLACE FUNCTION university_fees.fn_fee_balance(
    p_student_id INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN

    SELECT fee_due
    INTO v_fee
    FROM university_fees.students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found';
    END IF;

    SELECT COALESCE(SUM(amount),0)
    INTO v_paid
    FROM university_fees.payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;

END;
$$;

SELECT university_fees.fn_fee_balance(1);

--C--

CREATE OR REPLACE PROCEDURE university_fees.pr_receive_payment(
    p_student_id INTEGER,
    p_amount NUMERIC(12,2),
    p_paid_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive';
    END IF;

    v_balance :=
        university_fees.fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION
        'Payment exceeds outstanding balance';
    END IF;

    INSERT INTO university_fees.payments
    (
        student_id,
        amount,
        paid_on
    )
    VALUES
    (
        p_student_id,
        p_amount,
        p_paid_on
    );

END;
$$;

CALL university_fees.pr_receive_payment(1,1000,'2026-11-01');
CALL university_fees.pr_receive_payment(1,500,'2026-11-02');
CALL university_fees.pr_receive_payment(1,800,'2026-11-03');

CALL university_fees.pr_receive_payment(2,1000,'2026-11-01');
CALL university_fees.pr_receive_payment(2,1200,'2026-11-02');
CALL university_fees.pr_receive_payment(2,500,'2026-11-03');

--D--

CREATE OR REPLACE FUNCTION
university_fees.fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    INSERT INTO university_fees.payment_audit
    (
        payment_id,
        student_id,
        amount,
        logged_at
    )
    VALUES
    (
        NEW.payment_id,
        NEW.student_id,
        NEW.amount,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;

END;
$$;
--trigger--
CREATE TRIGGER trg_payment_audit
AFTER INSERT
ON university_fees.payments
FOR EACH ROW
EXECUTE FUNCTION university_fees.fn_payment_audit();

--E--

CREATE OR REPLACE VIEW university_fees.v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    s.fee_due
      - COALESCE(SUM(p.amount),0)
      AS outstanding_balance
FROM university_fees.students s
LEFT JOIN university_fees.payments p
ON s.student_id = p.student_id
GROUP BY
    s.student_number,
    s.full_name,
    s.fee_due
HAVING
    s.fee_due - COALESCE(SUM(p.amount),0) > 0;

SELECT *
FROM university_fees.v_fee_balances;

--F--
CREATE INDEX idx_payments_student_date
ON university_fees.payments
(
    student_id,
    paid_on
);

EXPLAIN

SELECT *
FROM university_fees.payments
WHERE student_id = 1
AND paid_on BETWEEN
    DATE '2026-11-01'
AND DATE '2026-11-30';

--G--

CREATE OR REPLACE PROCEDURE
university_fees.pr_refresh_collections(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
    v_total NUMERIC(12,2);
BEGIN

    SELECT
        COUNT(*),
        COALESCE(SUM(amount),0)
    INTO
        v_count,
        v_total
    FROM university_fees.payments
    WHERE paid_on = p_day;

    INSERT INTO university_fees.daily_collections
    (
        collection_date,
        payment_count,
        total_amount
    )
    VALUES
    (
        p_day,
        v_count,
        v_total
    )

    ON CONFLICT (collection_date)
    DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;

END;
$$;
