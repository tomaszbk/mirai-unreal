package fab

@(private)
browser_command :: proc(url:string) -> []string {
    command:=make([]string,2,context.temp_allocator)
    command[0],command[1]="xdg-open",url
    return command
}
