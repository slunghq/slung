const cli = @import("cli.zig");

pub fn main(init: @import("std").process.Init) void {
    cli.run(init);
}
