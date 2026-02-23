import rz
import strformat
import debby/sqlite
import strutils, strformat

template initTable*[T](db: DB, model:typedesc[T]) = 
    if not db.tableExists model : db.createTable model
    db.checkTable(model)

proc getBool*(query : seq[seq[string]]) : rz.Rz[bool] = 
    if query.len == 0: return err[bool]"No result returned by the query"

    let value = query[0][0]
    case value:
        of "0": return ok true
        of "1": return ok false
        else  : return err[bool] &"Invalid boolean value: {value}"

proc getInt*(query : seq[seq[string]]) : rz.Rz[int] = 
    if query.len == 0: return err[int]"No result returned by the query"

    let value = query[0][0]
    try:
        return ok parseInt(value)
    except Exception as e:
        return err[int] &"Error parsing value into into value: {value}, Error: {e.msg}"

    runnableExamples:
        block get_num_of_uncompleted_react_requests:
            num_of_uncompleted_react_requests = db.query(&"""
                SELECT COUNT(id) 
                FROM react_request
                WHERE 
                    reviewer_id   = {ctx.auth.user.get.id}      AND
                    paid_for_at   > 0      AND
                    completed_at  = 0
                """
            ).getInt.catch:
                let msg = &"Error fetching number of uncompleted react requests for user {this_user.id}: {it.err}"
                icr msg
                tsnh msg
                break get_num_of_uncompleted_react_requests

            icb  num_of_uncompleted_react_requests

proc getString_strict*(query : seq[seq[string]]) : rz.Rz[string] = 
    if query.len == 0: return err[string]"No result returned by the query"

    let value = query[0][0]
    if value.len == 0 :
        return err[string]"Empty string returned by the query"
    
    return ok value


proc safeUpdate*(db:DB, query_string: string): rz.Rz[bool] =
    try:
        db.query(query_string)
        return ok true
    except Exception as e:
        return err[false] &"Error updating database: {e.msg}"