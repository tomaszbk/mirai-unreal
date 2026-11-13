package fab

@(private)
browser_command :: proc(url:string) -> []string {
    command:=make([]string,3,context.temp_allocator)
    command[0],command[1],command[2]="rundll32","url.dll,FileProtocolHandler",url
    return command
}
