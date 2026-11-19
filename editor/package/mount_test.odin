package unreal

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The engine content is that of the newest installation the places name
// that holds one: in a folder of installations or recorded by the launcher
// wherever it is, its version from its Build.version or its folder name; a
// recorded folder that is gone or holds no content is left out.
@(test)
the_newest_installation_with_engine_content_is_found_where_the_launcher_puts_or_records_it :: proc(t:^testing.T) {
    root,error:=os.make_directory_temp("","mirai-engines-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(root)
    install :: proc(root,folder:string,version:string,content:bool) -> string {
        at,_:=filepath.join({root,folder},context.temp_allocator)
        engine,_:=filepath.join({at,"Engine","Build"},context.temp_allocator)
        _=os.make_directory_all(engine)
        if content {
            c,_:=filepath.join({at,"Engine","Content"},context.temp_allocator)
            _=os.make_directory_all(c)
        }
        if version!="" {
            major,_,minor:=strings.partition(version,".")
            b,_:=filepath.join({engine,"Build.version"},context.temp_allocator)
            _=os.write_entire_file(b,transmute([]u8)fmt.tprintf(`{{"MajorVersion": %s, "MinorVersion": %s, "PatchVersion": 0}}`,major,minor))
        }
        return at
    }
    write :: proc(root,name,text:string) -> string {
        path,_:=filepath.join({root,name},context.temp_allocator)
        _=os.write_entire_file(path,transmute([]u8)text)
        return path
    }
    json_path :: proc(s:string) -> string {out,_:=strings.replace_all(s,"\\","\\\\",context.temp_allocator);return out}
    launcher,_:=filepath.join({root,"Program Files","Epic Games"},context.temp_allocator)
    home,_:=filepath.join({root,"home","Epic Games"},context.temp_allocator)
    old:=install(launcher,"UE_5.7","",true)
    _=install(launcher,"UE_5.9","5.9",false)
    chosen:=install(root,"Engines/Mine","5.8",true)
    homed:=install(home,"UE_5.10","",true)
    stale,_:=filepath.join({root,"gone","UE_6.0"},context.temp_allocator)
    list:=write(root,"installations.jsonl",fmt.tprintf("{{\"dir\": \"%s\", \"artifactId\": \"UE_5.8\"}}\n{{\"dir\": \"%s\", \"artifactId\": \"UE_6.0\"}}\nnot json\n",json_path(chosen),json_path(stale)))
    built:=install(root,"Source/Build","5.11",true)
    ini:=write(root,"Install.ini",fmt.tprintf("[Installations]\nABC=%s\nDEF=%s\n",built,stale))
    content :: proc(at:string) -> string {c,_:=filepath.join({at,"Engine","Content"},context.temp_allocator);return c}
    cases:=[]struct {name:string,places:Engine_Places,expected:string}{
        {"the launcher's folder, the newest with content",{folders={launcher}},content(old)},
        {"recorded where the user put it",{folders={launcher},lists={list}},content(chosen)},
        {"the folder under the home, numbers compared",{folders={launcher,home},lists={list}},content(homed)},
        {"a registered build",{folders={launcher,home},lists={list},builds={ini}},content(built)},
        {"only gone or empty folders",{lists={write(root,"empty.jsonl",fmt.tprintf("{{\"dir\": \"%s\"}}\n",json_path(stale)))}},""},
        {"nothing",{},""},
    }
    for c in cases {
        found:=engine_content_in(c.places)
        testing.expectf(t,found==c.expected,"%s: %q, not %q",c.name,found,c.expected)
    }
}
