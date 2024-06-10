const std = @import("std");
const print = std.debug.print;
const builtin = @import("builtin");
const net = std.net;
const windows = std.os.windows;
const linux = std.os.linux;

// POLLIN, POLLERR, POLLHUP, POLLNVAL 都是poll事件

/// windows context定义
const windows_context = struct {
    const POLLIN: i16 = 0x0100;
    const POLLERR: i16 = 0x0001;
    const POLLHUP: i16 = 0x0002;
    const POLLNVAL: i16 = 0x0004;
    const INVALID_SOCKET = windows.ws2_32.INVALID_SOCKET;
};

/// linux context定义
const linux_context = struct {
    const POLLIN: i16 = 0x0001;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;
    const POLLNVAL: i16 = 0x0020;
    const INVALID_SOCKET = -1;
};

/// macOS context 定义
const macos_context = struct {
    const POLLIN: i16 = 0x0001;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;
    const POLLNVAL: i16 = 0x0020;
    const INVALID_SOCKET = -1;
};

const context = switch (builtin.os.tag) {
    .windows => windows_context,
    .linux => linux_context,
    .macos => macos_context,
    else => @compileError("unsupported os"),
};

pub fn main() !void {
    // #region listen
	// 解析地址
	const port = 8080;
	const address = try net.Address.parseIp4("127.0.0.1", port);
	// 初始化一个server，这里包含了socket()和bind()两个过程
	var server = try address.listen(.{ .reuse_port = true });
	defer server.deinit();
	// #endregion listen

	// #region data
	// 定义最大连接数
	const max_sockets = 1000;
	// buffer用于存储client发过来的数据
	var buf: [1024]u8 = std.mem.zeroes([1024]u8);
	// 存储accept拿到的connections
	var connections: [max_sockets]?net.Server.Connection = undefined;
	// sockfds用于存储pollfd, 用于传递给poll函数
	var sockfds: [max_sockets]if (builtin.os.tag == .windows) windows.ws2_32.pollfd else std.posix.pollfd = undefined;
	// #endregion data

	for (0..max_sockets) |i| {
		sockfds[i].fd = context.INVALID_SOCKET;
		sockfds[i].events = context.POLLIN;
		connections[i] = null;
	}
	sockfds[0].fd = server.stream.handle;
	std.log.info("start listening at {d}...", .{port});

	// 无限循环，等待客户端连接 或 已连接的客户端发送数据
	while (true) {
		// 调用poll, nums是返回的事件数量
		var nums = if (builtin.os.tag == .windows) windows.poll(&sockfds, max_sockets, -1) else try std.posix.poll(&sockfds, -1);
		if (nums == 0) {
			continue;
		}
		// 如果返回的事件数量小于0，说明出错了
		//  仅仅在windows下会出现这种情况
		if (nums < 0) {
			@panic("An error occurred in poll");
		}

		// 注意：使用的模型是先处理已连接的客户端，再处理新连接的客户端

		// #region exist-connections
		// 遍历所有的连接，处理事件
		for (1..max_sockets) |i| {
			// 这里的nums是poll返回的事件数量
			//  在windows下，WSApoll允许返回0，未超时且没有套接字处于指定的状态
			if (nums == 0) {
				break;
			}
			const sockfd = sockfds[i];
			// 检查是否是无效的socket
			if (sockfd.fd == context.INVALID_SOCKET) {
				continue;
			}

			// 由于windows针对无效的socket也会触发POLLNVAL
			//  当前sock有IO事件时，处理完后将nums减-
			defer if (sockfd.revents != 0) {
				nums -= 1;
			};

			// 检查是否是POLLIN事件，即：是否有数据可读
			if (sockfd.revents & (context.POLLIN) != 0) {
				const c = connections[i];
				if (c) |connection| {
					const len = try connection.stream.read(&buf);
					// 如果连接已经断开，那么关闭连接
					//  这是因为如果已经close连接，读取的时候会返回0
					if (len == 0) {
						// 但为了保险起见，还是调用close
						//  因为有可能是连接没有断开，但是出现了错误
						connection.stream.close();
						// 将pollfd和connection置为无效
						sockfds[i].fd = context.INVALID_SOCKET;
						std.log.info("client from {any} close!", .{
							connection.address,
						});
						connections[i] = null;
					} else {
						// 如果读取到了数据，那么将数据写回去
						//  但仅仅这样写一次并不安全
						//  最优解应该是使用for循环检测写入的数据大小是否等于buf长度
						//  如果不等于就继续写入
						//  这是因为TCP是一个面向流的协议，并不保证一次write调用能够发送所有的数据
						//  作为示例，不检查是否全部写入
						_ = try connection.stream.write(buf[0..len]);
					}
				}
			}
			// 检查是否是POLLNVAL | POLLERR | POLLHUP事件，即：是否有错误发生，或者连接断开
			else if (sockfd.revents & (context.POLLNVAL | context.POLLERR | context.POLLHUP) != 0) {
				// 将pollfd和connection置为无效
				sockfds[i].fd = context.INVALID_SOCKET;
				connections[i] = null;
				std.log.info("client {} close", .{i});
			}
		}
		// #endregion exist-connections

		// #region new-connection
		// 检查是否有新的连接
		//  这里的sockfds[0]是server的pollfd
		//  这里的nums检查可有可无，因为只关心是否有新的连接，POLLIN就足够了
		if (sockfds[0].revents & context.POLLIN != 0 and nums > 0) {
			std.log.info("new client", .{});
			// 如果有新的连接，那么调用accept
			const client = try server.accept();
			for (1..max_sockets) |i| {
				// 找到一个空的pollfd，将新的连接放进去
				if (sockfds[i].fd == context.INVALID_SOCKET) {
					sockfds[i].fd = client.stream.handle;
					connections[i] = client;
					std.log.info("new client {} comes", .{i});
					break;
				}
				// 如果没有找到空的pollfd，那么说明连接数已经达到了最大值
				if (i == max_sockets - 1) {
					@panic("too many clients");
				}
			}
		}
		// #endregion new-connection
	}

	if (builtin.os.tag == .windows) {
		try windows.ws2_32.WSACleanup();
	}
}