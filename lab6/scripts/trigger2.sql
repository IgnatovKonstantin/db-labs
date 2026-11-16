/*
Триггер 2. Защита финансового журнала продавца 
При изменении или удалении финансовой операции проверять её статус. Если операция 
уже проведена, запрещать изменение любых её данных и удаление. Исправления должны 
выполняться отдельной сторнирующей операцией с обязательной ссылкой на исходную 
запись.
*/

CREATE OR REPLACE FUNCTION protect_financial_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'Проведена' THEN
        RAISE EXCEPTION 'Операция с operation_id=% проведена и не может быть изменена или удалена', OLD.operation_id;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_protect_financial_operation
BEFORE UPDATE OR DELETE ON financial_operation
FOR EACH ROW EXECUTE FUNCTION protect_financial_operation();