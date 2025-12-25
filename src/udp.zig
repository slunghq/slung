const std = @import("std");
const net = std.net;
const posix = std.posix;

pub const UdpStream = struct {
    socket: posix.socket_t,
    address: net.Address,

    pub fn init(address: net.Address) !UdpStream {
        const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        try posix.bind(socket, @ptrCast(&address), address.getOsSockLen());

        return UdpStream{
            .socket = socket,
            .address = address,
        };
    }

    pub fn deinit(self: *UdpStream) void {
        posix.close(self.socket);
    }

    pub fn send(self: *UdpStream, data: []const u8, dest_addr: *const posix.sockaddr) !usize {
        const addrlen: posix.socklen_t = @sizeOf(posix.sockaddr);
        return try posix.sendto(self.socket, data, 0, dest_addr, addrlen);
    }

    pub fn recv(self: *UdpStream, buffer: []u8, dest_addr: ?*posix.sockaddr) !usize {
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr);
        return try posix.recvfrom(self.socket, buffer, 0, dest_addr, &addrlen);
    }
};
