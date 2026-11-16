/*
-- Триггер 1. Контроль периодов действия цен 
При добавлении или изменении цены предложения проверять пересечение периода 
её действия с другими ценами того же предложения. Запрещать существование нескольких 
действующих цен на один момент времени. При обнаружении пересечения выводить 
ошибку с идентификатором конфликтующей записи.
*/

CREATE OR REPLACE FUNCTION check_offer_price_overlap()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$ 
DECLARE
    conflict_id BIGINT;
BEGIN 
    SELECT op.price_id INTO conflict_id
    FROM offer_price op
    WHERE op.offer_id = NEW.offer_id 
        AND op.price_id IS DISTINCT FROM NEW.price_id
        AND (op.starts_at, COALESCE(op.ends_at, 'infinity'::timestamptz)) 
            OVERLAPS 
            (NEW.starts_at, COALESCE(NEW.ends_at, 'infinity'::timestamptz));

    IF FOUND THEN 
        RAISE EXCEPTION 'Обнаружен конфликт периодов цен. Пересечение с записью с price_id=%', conflict_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_check_offer_price_overlap
BEFORE INSERT OR UPDATE ON offer_price
FOR EACH ROW EXECUTE FUNCTION check_offer_price_overlap();
