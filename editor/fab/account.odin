package fab

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

// The Epic account the library is read with. Signing in opens the Epic page
// of a device code in the browser; once the user signs in there and accepts,
// the sign in that waited for it trades the session of the device for one of
// the client Fab takes. That session is kept in the folder of the
// configuration of the user, never in a project, and its access is renewed
// with its refresh token until that one expires.

CLIENT :: "34a02cf8f4414e29b15921876da36f9a:daafbccc737745039dffe53d94fc76cf"        // the one Fab takes
DEVICE_CLIENT :: "98f7e42c2e3a4f86a74eb43fbb41ed39:0a2449a2-001a-451e-afec-3e812901c4d7" // one that signs in by a device code
CLIENT_ID :: "34a02cf8f4414e29b15921876da36f9a"
ACCOUNT_URL :: "https://account-public-service-prod.ol.epicgames.com/account/api/oauth"
SESSION_FILE :: "mirai/epic-session.json"

Session :: struct {
    access_token:string `json:"access_token"`,
    expires_at:string `json:"expires_at"`,
    refresh_token:string `json:"refresh_token"`,
    refresh_expires_at:string `json:"refresh_expires_at"`,
    account_id:string `json:"account_id"`,
    display_name:string `json:"displayName"`,
}

// What the token service answers besides a session.
@(private="file")
Token_Error :: struct {
    error_code:string `json:"errorCode"`,
    error_message:string `json:"errorMessage"`,
}

session_destroy :: proc(s:^Session,allocator:=context.allocator) {
    delete(s.access_token,allocator);delete(s.expires_at,allocator)
    delete(s.refresh_token,allocator);delete(s.refresh_expires_at,allocator)
    delete(s.account_id,allocator);delete(s.display_name,allocator)
    s^={}
}

// The header that authorizes a request of the account.
session_authorization :: proc(s:Session) -> string {return fmt.tprintf("bearer %s",s.access_token)}

// A sign in that waits for the user at the Epic page of url.
Device_Code :: struct {
    url:string `json:"verification_uri_complete"`,
    device_code:string `json:"device_code"`,
    expires_in:int `json:"expires_in"`, // s
    interval:int `json:"interval"`,     // s between asks
}

// Asks Epic for a device code whose page the user signs in at; in allocator.
sign_in_begin :: proc(allocator:=context.allocator) -> (d:Device_Code,problem:string) {
    client,client_problem:=token_post(DEVICE_CLIENT,"grant_type=client_credentials",context.temp_allocator)
    if client_problem!="" {return {},strings.clone(client_problem,allocator)}
    Client :: struct {access_token:string `json:"access_token"`}
    token:Client
    if json.unmarshal(client.body,&token,allocator=context.temp_allocator)!=nil || token.access_token=="" {return {},strings.clone("Epic gave no token to ask for a sign in",allocator)}
    response,send_problem:=http_send({url=ACCOUNT_URL+"/deviceAuthorization",post=true,authorization=fmt.tprintf("bearer %s",token.access_token),form="prompt=login"},context.temp_allocator)
    if send_problem!="" {return {},strings.clone(send_problem,allocator)}
    if response.status!=200 || json.unmarshal(response.body,&d,allocator=allocator)!=nil || d.device_code=="" || !strings.has_prefix(d.url,"https://") {
        return {},fmt.aprintf("Epic did not give a sign in (%d): %s",response.status,text_head(response.body),allocator=allocator)
    }
    return d,""
}

// Waits until the user accepts the sign in of d at its page, it expires or
// cancel is set, and keeps the session it gives.
sign_in_wait :: proc(d:Device_Code,cancel:^bool,allocator:=context.allocator) -> (s:Session,problem:string) {
    started:=time.tick_now()
    interval:=time.Duration(clamp(d.interval,1,60))*time.Second
    device:Session
    for {
        if time.tick_since(started)>time.Duration(max(d.expires_in,60))*time.Second {return {},strings.clone("the sign in expired before it was accepted at the Epic page: sign in again",allocator)}
        for waited:=time.Duration(0);waited<interval;waited+=100*time.Millisecond {
            if sync_load(cancel) {return {},strings.clone("the sign in was stopped",allocator)}
            time.sleep(100*time.Millisecond)
        }
        response,send_problem:=token_post(DEVICE_CLIENT,fmt.tprintf("grant_type=device_code&device_code=%s",url_encode(d.device_code,context.temp_allocator)),context.temp_allocator)
        if send_problem!="" {return {},strings.clone(send_problem,allocator)}
        if response.status==200 {
            if json.unmarshal(response.body,&device,allocator=context.temp_allocator)!=nil || device.access_token=="" {return {},strings.clone("Epic accepted the sign in without a session",allocator)}
            break
        }
        failure:Token_Error
        _=json.unmarshal(response.body,&failure,allocator=context.temp_allocator)
        switch failure.error_code {
        case "errors.com.epicgames.account.oauth.authorization_pending","errors.com.epicgames.common.slow_down": continue
        case "errors.com.epicgames.account.oauth.authorization_declined": return {},strings.clone("the sign in was declined at the Epic page",allocator)
        case "errors.com.epicgames.not_found","errors.com.epicgames.account.oauth.expired_device_code": return {},strings.clone("the sign in expired before it was accepted at the Epic page: sign in again",allocator)
        }
        return {},fmt.aprintf("Epic refused the sign in (%d): %s",response.status,failure.error_message if failure.error_message!="" else text_head(response.body),allocator=allocator)
    }
    // The session of the device makes a code that the client Fab takes trades
    // for a session of its own; the one of the device is ended.
    bearer:=fmt.tprintf("bearer %s",device.access_token)
    defer {_,_=http_send({url=fmt.tprintf("%s/sessions/kill/%s",ACCOUNT_URL,device.access_token),method="DELETE",authorization=bearer},context.temp_allocator)}
    exchange,exchange_problem:=http_send({url=fmt.tprintf("%s/exchange?consumingClientId=%s",ACCOUNT_URL,CLIENT_ID),authorization=bearer},context.temp_allocator)
    if exchange_problem!="" {return {},strings.clone(exchange_problem,allocator)}
    Exchange :: struct {code:string `json:"code"`}
    code:Exchange
    if exchange.status!=200 || json.unmarshal(exchange.body,&code,allocator=context.temp_allocator)!=nil || code.code=="" {
        return {},fmt.aprintf("Epic did not trade the sign in (%d): %s",exchange.status,text_head(exchange.body),allocator=allocator)
    }
    return token_request(fmt.tprintf("grant_type=exchange_code&exchange_code=%s&token_type=eg1",url_encode(code.code,context.temp_allocator)),allocator)
}

@(private="file")
token_post :: proc(client,form:string,allocator:=context.allocator) -> (response:Response,problem:string) {
    return http_send({url=ACCOUNT_URL+"/token",post=true,basic=client,form=form},allocator)
}

// The kept session, with its access renewed when it expired; found is false
// when there is none or it can no longer be renewed.
session_load :: proc(allocator:=context.allocator) -> (s:Session,found:bool,problem:string) {
    path:=session_path(context.temp_allocator)
    if path=="" || !os.is_file(path) {return}
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    if read_error!=nil {return {},false,fmt.aprintf("%s cannot be read: %v",path,read_error,allocator=allocator)}
    kept:Session
    if json.unmarshal(data,&kept,allocator=context.temp_allocator)!=nil || kept.refresh_token=="" {return}
    if !expired(kept.expires_at,5*time.Minute) {
        if clone_into(&s,kept,allocator) {return s,true,""}
        return {},false,strings.clone("there is no memory for the session",allocator)
    }
    if expired(kept.refresh_expires_at,0) {return}
    s,problem=token_request(fmt.tprintf("grant_type=refresh_token&refresh_token=%s&token_type=eg1",url_encode(kept.refresh_token,context.temp_allocator)),allocator)
    return s,problem=="",problem
}

// Forgets the kept session.
// Ends the kept session at Epic, so that its tokens stop working wherever
// they are, and forgets it.
session_logout :: proc(allocator:=context.allocator) -> (problem:string) {
    s,found,load_problem:=session_load(context.temp_allocator)
    if found {
        response,send_problem:=http_send({url=fmt.tprintf("%s/sessions/kill/%s",ACCOUNT_URL,s.access_token),method="DELETE",authorization=session_authorization(s)},context.temp_allocator)
        if send_problem!="" {return strings.clone(send_problem,allocator)}
        if response.status!=204 && response.status!=200 && response.status!=401 {return fmt.aprintf("Epic did not end the session (%d): %s",response.status,text_head(response.body),allocator=allocator)}
    } else if load_problem!="" {
        return strings.clone(load_problem,allocator)
    }
    if path:=session_path(context.temp_allocator);path!="" && os.exists(path) {
        if error:=os.remove(path);error!=nil {return fmt.aprintf("%s cannot be removed: %v",path,error,allocator=allocator)}
    }
    return ""
}

// Asks the token service for a session with form and keeps it.
@(private="file")
token_request :: proc(form:string,allocator:=context.allocator) -> (s:Session,problem:string) {
    response,send_problem:=token_post(CLIENT,form,context.temp_allocator)
    if send_problem!="" {return {},strings.clone(send_problem,allocator)}
    if response.status!=200 {
        failure:Token_Error
        _=json.unmarshal(response.body,&failure,allocator=context.temp_allocator)
        if failure.error_code=="errors.com.epicgames.account.auth_token.invalid_refresh_token" {
            return {},strings.clone("Epic no longer takes the session: sign in again",allocator)
        }
        return {},fmt.aprintf("Epic refused to sign in (%d): %s",response.status,failure.error_message if failure.error_message!="" else string(response.body),allocator=allocator)
    }
    got:Session
    if json.unmarshal(response.body,&got,allocator=context.temp_allocator)!=nil || got.access_token=="" || got.account_id=="" {
        return {},strings.clone("Epic answered the sign in without a session",allocator)
    }
    if !clone_into(&s,got,allocator) {return {},strings.clone("there is no memory for the session",allocator)}
    if path:=session_path(context.temp_allocator);path!="" {
        // Only the user may read it.
        text,_:=json.marshal(got,{pretty=true},context.temp_allocator)
        _=os.make_directory_all(filepath.dir(path))
        if file,error:=os.open(path,{.Write,.Create,.Trunc},{.Read_User,.Write_User});error==nil {
            _,_=os.write(file,text)
            os.close(file)
        }
    }
    return s,""
}

@(private="file")
sync_load :: proc(flag:^bool) -> bool {return sync.atomic_load(flag)}

@(private="file")
session_path :: proc(allocator:=context.allocator) -> string {
    folder,error:=os.user_config_dir(context.temp_allocator)
    if error!=nil || folder=="" {return ""}
    return path_join({folder,SESSION_FILE},allocator)
}

// Whether the time stamp is past, or within margin of it; one that cannot
// be read is past.
@(private="file")
expired :: proc(stamp:string,margin:time.Duration) -> bool {
    at,consumed:=time.rfc3339_to_time_utc(stamp)
    if consumed==0 {return true}
    return time.diff(time.now(),at)<margin
}

@(private="file")
clone_into :: proc(s:^Session,from:Session,allocator:=context.allocator) -> bool {
    fields:=[?]^string{&s.access_token,&s.expires_at,&s.refresh_token,&s.refresh_expires_at,&s.account_id,&s.display_name}
    values:=[?]string{from.access_token,from.expires_at,from.refresh_token,from.refresh_expires_at,from.account_id,from.display_name}
    for field,i in fields {
        text,error:=clone(values[i],allocator)
        if error!=nil {session_destroy(s,allocator);return false}
        field^=text
    }
    return true
}
