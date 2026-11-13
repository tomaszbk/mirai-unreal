package fab

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "mirai:std/base"
import "mirai:std/subprocess"

// Requests go through curl, which every supported system ships. What a
// request carries (a token among them) goes in a config file of a folder of
// its own, never on the command line, and the folder is removed once curl
// ends.

USER_AGENT :: "UELauncher/17.0.1-37584233+++Portal+Release-Live Windows/10.0.19043.1.0.64bit"
PARALLEL :: 16 // files a download fetches at once

Request :: struct {
    url:string,
    post:bool,
    method:string,        // another than GET or POST, "" for none
    authorization:string, // the value of the header, "" for none
    basic:string,         // user:password, "" for none
    form:string,          // a body urlencoded, "" for none
    json:string,          // a body of JSON, "" for none
}

Response :: struct {status:int,body:[]u8}

// Sends one request and gives its status and body in allocator; the problem
// says why there is no answer (the network, curl), not a status that is not 2xx.
http_send :: proc(request:Request,allocator:=context.allocator) -> (response:Response,problem:string) {
    folder,folder_error:=os.make_directory_temp("","mirai-fab-*",context.temp_allocator)
    if folder_error!=nil {return {},fmt.aprintf("a temporary folder cannot be made: %v",folder_error,allocator=allocator)}
    defer base.remove_all(folder)
    body:=path_join({folder,"body"},context.temp_allocator)
    config:=strings.builder_make(context.temp_allocator)
    config_common(&config)
    config_line(&config,"url",request.url)
    config_line(&config,"output",body)
    config_line(&config,"write-out","%{http_code}")
    if request.post {config_line(&config,"request","POST")}
    if request.method!="" {config_line(&config,"request",request.method)}
    if request.authorization!="" {config_line(&config,"header",fmt.tprintf("Authorization: %s",request.authorization))}
    if request.basic!="" {config_line(&config,"user",request.basic)}
    if request.form!="" {
        config_line(&config,"header","Content-Type: application/x-www-form-urlencoded")
        config_line(&config,"data-raw",request.form)
    }
    if request.json!="" {
        config_line(&config,"header","Content-Type: application/json")
        config_line(&config,"data-raw",request.json)
    }
    out,problem_text:=curl_run(folder,strings.to_string(config))
    if problem_text!="" {return {},strings.clone(problem_text,allocator)}
    status,parsed:=strconv.parse_int(strings.trim_space(out))
    if !parsed {return {},fmt.aprintf("curl gave no status for %s",url_shown(request.url),allocator=allocator)}
    data,_:=os.read_entire_file(body,allocator)
    return {status,data},""
}

// A file to fetch and where it goes.
Fetch :: struct {url,path:string}

// Fetches the files of fetches into their paths, PARALLEL at once. The
// problem names the first that could not be fetched.
http_fetch :: proc(fetches:[]Fetch,allocator:=context.allocator) -> (problem:string) {
    if len(fetches)==0 {return ""}
    folder,folder_error:=os.make_directory_temp("","mirai-fab-*",context.temp_allocator)
    if folder_error!=nil {return fmt.aprintf("a temporary folder cannot be made: %v",folder_error,allocator=allocator)}
    defer base.remove_all(folder)
    config:=strings.builder_make(context.temp_allocator)
    config_common(&config)
    config_line(&config,"fail","")
    config_line(&config,"parallel","")
    config_line(&config,"parallel-max",fmt.tprint(PARALLEL))
    config_line(&config,"retry","3")
    config_line(&config,"create-dirs","")
    for f in fetches {
        config_line(&config,"url",f.url)
        config_line(&config,"output",f.path)
    }
    _,problem_text:=curl_run(folder,strings.to_string(config))
    if problem_text!="" {return strings.clone(problem_text,allocator)}
    for f in fetches {
        if !os.is_file(f.path) {return fmt.aprintf("%s could not be fetched",url_shown(f.url),allocator=allocator)}
    }
    return ""
}

@(private="file")
config_common :: proc(b:^strings.Builder) {
    config_line(b,"silent","")
    config_line(b,"show-error","")
    config_line(b,"location","")
    config_line(b,"user-agent",USER_AGENT)
}

// A line of a curl config: the option, and its value quoted.
@(private="file")
config_line :: proc(b:^strings.Builder,option,value:string) {
    strings.write_string(b,option)
    if value!="" {
        strings.write_string(b," = \"")
        for c in transmute([]u8)value {
            switch c {
            case '"','\\': strings.write_byte(b,'\\');strings.write_byte(b,c)
            case '\n':     strings.write_string(b,"\\n")
            case '\r':     strings.write_string(b,"\\r")
            case '\t':     strings.write_string(b,"\\t")
            case:          strings.write_byte(b,c)
            }
        }
        strings.write_byte(b,'"')
    }
    strings.write_byte(b,'\n')
}

// Runs curl with config; what it wrote to stdout, or what failed, in the
// temporary allocator.
@(private="file")
curl_run :: proc(folder,config:string) -> (out,problem:string) {
    path:=path_join({folder,"config"},context.temp_allocator)
    if error:=os.write_entire_file(path,transmute([]u8)config);error!=nil {return "",fmt.tprintf("the request cannot be written: %v",error)}
    state,stdout,stderr,error:=subprocess.exec({command={curl_path(),"--config",path}},context.temp_allocator)
    if error!=nil {return "",fmt.tprintf("curl cannot run (%v): install curl or put it on the PATH",error)}
    if state.exit_code!=0 {
        text:=strings.trim_space(string(stderr))
        if text=="" {text=fmt.tprintf("it ended with %d",state.exit_code)}
        return "",fmt.tprintf("curl: %s",text)
    }
    return string(stdout),""
}

// A URL as a message shows it: without its query, which may be a signature.
url_shown :: proc(url:string) -> string {
    if at:=strings.index_byte(url,'?');at>=0 {return url[:at]}
    return url
}

// Text for a URL or a form, percent-encoded.
url_encode :: proc(text:string,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    for c in transmute([]u8)text {
        if c>='A' && c<='Z' || c>='a' && c<='z' || c>='0' && c<='9' || c=='-' || c=='_' || c=='.' || c=='~' {strings.write_byte(&b,c);continue}
        fmt.sbprintf(&b,"%%%02X",c)
    }
    return strings.to_string(b)
}

// curl of the system: on Windows the one Windows ships, before any other on
// the PATH.
@(private="file")
curl_path :: proc() -> string {
    when ODIN_OS==.Windows {
        if windows,found:=os.lookup_env("SystemRoot",context.temp_allocator);found {
            if candidate:=path_join({windows,"System32","curl.exe"},context.temp_allocator);os.is_file(candidate) {return candidate}
        }
    }
    return "curl"
}

// The parts joined into a path.
path_join :: proc(parts:[]string,allocator:=context.allocator) -> string {
    joined,_:=filepath.join(parts,allocator)
    return joined
}
