const std = @import("std");

const fatfs = @import("zfat");

// requires pointer stability
var global_fs: fatfs.FileSystem = undefined;

// requires pointer stability
var image_disk: Disk = undefined;

pub fn main(init: std.process.Init) !u8 {
    image_disk = .{
        .sectors = try std.heap.page_allocator.alloc([Disk.sector_size]u8, 100_000), // ~40 MB
    };
    defer std.heap.page_allocator.free(image_disk.sectors);

    fatfs.disks[0] = &image_disk.interface;
    fatfs.std_io = init.io;

    var workspace: [4096]u8 = undefined;
    try fatfs.mkfs("0:", .{
        .filesystem = .fat32,
        .sector_align = 1,
        .use_partitions = true,
    }, &workspace);

    try global_fs.mount("0:", true);
    defer fatfs.FileSystem.unmount("0:") catch |e| std.log.err("failed to unmount filesystem: {s}", .{@errorName(e)});

    {
        var file = try fatfs.File.create("0:/firmware.uf2");
        defer file.close();

        var buffer: [64]u8 = undefined;

        const test_string = "Hello, World!\r\n";

        var writer = file.writer(&buffer);
        try writer.writer.writeAll(test_string);
        try writer.writer.flush();

        try std.testing.expectEqual(true, file.endOfFile());
        try std.testing.expectEqual(test_string.len, file.size());

        try file.seekTo(test_string.len / 2);
        try std.testing.expectEqual(false, file.endOfFile());
        try std.testing.expectEqual(test_string.len / 2, file.tell());
        try std.testing.expectEqual(test_string.len, file.size());

        try std.testing.expectEqual(false, file.hasError());

        try file.rewind();
        try std.testing.expectEqual(0, file.tell());

        var reader = file.reader(&buffer);
        const written_string = try reader.reader.take(test_string.len);
        try std.testing.expectEqualStrings(test_string, written_string);

        _ = try file.sync();
        _ = try file.truncate();
    }

    return 0;
}

pub const Disk = struct {
    const sector_size = 512;

    interface: fatfs.Disk = fatfs.Disk{
        .getStatusFn = getStatus,
        .initializeFn = initialize,
        .readFn = read,
        .writeFn = write,
        .ioctlFn = ioctl,
    },
    sectors: [][sector_size]u8,

    pub fn getStatus(interface: *fatfs.Disk) fatfs.Disk.Status {
        const self: *Disk = @fieldParentPtr("interface", interface);
        _ = self;
        return fatfs.Disk.Status{
            .initialized = true,
            .disk_present = true,
            .write_protected = false,
        };
    }

    pub fn initialize(interface: *fatfs.Disk) fatfs.Disk.Error!fatfs.Disk.Status {
        const self: *Disk = @fieldParentPtr("interface", interface);
        return getStatus(&self.interface);
    }

    pub fn read(interface: *fatfs.Disk, _: std.Io, buff: [*]u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
        const self: *Disk = @fieldParentPtr("interface", interface);

        std.log.info("read({*}, {}, {})", .{ buff, sector, count });

        var sectors: std.Io.Reader = .fixed(std.mem.sliceAsBytes(self.sectors));
        sectors.discardAll(sector * sector_size) catch return error.IoError;
        sectors.readSliceAll(buff[0 .. sector_size * count]) catch return error.IoError;
    }

    pub fn write(interface: *fatfs.Disk, _: std.Io, buff: [*]const u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
        const self: *Disk = @fieldParentPtr("interface", interface);

        std.log.info("write({*}, {}, {})", .{ buff, sector, count });

        const slice = std.mem.sliceAsBytes(self.sectors);
        if (sector * sector_size > slice.len) return error.IoError;
        var sectors: std.Io.Writer = .fixed(slice[sector * sector_size ..]);
        sectors.writeAll(buff[0 .. sector_size * count]) catch return error.IoError;
    }

    pub fn ioctl(interface: *fatfs.Disk, _: std.Io, cmd: fatfs.IoCtl, buff: [*]u8) fatfs.Disk.Error!void {
        const self: *Disk = @fieldParentPtr("interface", interface);

        switch (cmd) {
            .sync => {},
            .get_sector_count => {
                @as(*align(1) fatfs.LBA, @ptrCast(buff)).* = @intCast(self.sectors.len);
            },
            else => {
                std.log.err("invalid ioctl: {}", .{cmd});
                return error.InvalidParameter;
            },
        }
    }
};
