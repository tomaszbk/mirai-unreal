package fab

import "mirai:std/subprocess"

// Opens url in the browser of the system, without waiting for it.
browser_open :: proc(url:string) -> bool {
    process,error:=subprocess.detached({command=browser_command(url)})
    if error!=nil {return false}
    subprocess.release(&process)
    return true
}
