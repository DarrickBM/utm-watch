import Foundation

/// How full a VM's disks are: what is in use against how much they hold.
public struct DiskUsage: Equatable {
    public var usedBytes: UInt64
    public var sizeBytes: UInt64
    /// True when the figures were read from the guest's own filesystem; false when `usedBytes` is the room the disk
    /// image takes on the Mac and `sizeBytes` the size the disk was created with, which is the best that can be said
    /// of a filesystem that cannot be read from outside.
    public var exact: Bool
    /// What was read: "APFS", "ext4", "Btrfs", "XFS", "NTFS", or "image" for the fallback.
    public var source: String
    public init(usedBytes: UInt64, sizeBytes: UInt64, exact: Bool, source: String = "") {
        self.usedBytes = usedBytes; self.sizeBytes = sizeBytes; self.exact = exact; self.source = source
    }
}

/// Reads disk usage from a VM's disk image files without mounting them and without asking the guest.
///
/// The guest's main filesystem keeps its own count of the space in use, and that count is what is reported: APFS
/// (macOS guests), ext2/3/4, Btrfs and XFS (Linux guests, also inside LVM) and NTFS (Windows guests), in raw images
/// and in QEMU's qcow2 format. Anything else falls back to the room the image takes on the Mac. Everything is opened
/// read-only. A running VM keeps writing to its image, so what is read is checked (magic numbers, checksums where the
/// format has them, sane sizes) and a reading that does not check out is dropped rather than shown.
public enum DiskImages {
    /// The writable disk images a UTM configuration lists, as file names inside the bundle's Data folder.
    public static func imageNames(plist: [String: Any]) -> [String] {
        let drives = plist["Drive"] as? [[String: Any]] ?? []
        return drives.compactMap { d -> String? in
            guard let name = d["ImageName"] as? String, !name.isEmpty else { return nil }
            if (d["ReadOnly"] as? Bool) == true { return nil }
            if let type = d["ImageType"] as? String, type.lowercased() != "disk" { return nil }
            return name
        }
    }

    /// Usage summed over a VM's disks; nil when it has none or none could be read.
    public static func usage(bundle: UTMBundle) -> DiskUsage? {
        var total: DiskUsage?
        for name in bundle.diskImages {
            guard let one = usage(image: bundle.url.appendingPathComponent("Data").appendingPathComponent(name)) else { continue }
            guard let sum = total else { total = one; continue }
            total = DiskUsage(usedBytes: sum.usedBytes &+ one.usedBytes, sizeBytes: sum.sizeBytes &+ one.sizeBytes,
                              exact: sum.exact && one.exact, source: sum.source == one.source ? sum.source : "\(sum.source) + \(one.source)")
        }
        return total
    }

    public static func usage(image url: URL) -> DiskUsage? {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_size > 0 else { return nil }
        let fileSize = UInt64(st.st_size)
        let onMac = min(UInt64(max(0, st.st_blocks)) * 512, fileSize)
        guard let file = FileSource(path: url.path, size: fileSize) else { return nil }
        defer { file.close() }

        var disk: ByteSource = file
        var diskSize = fileSize
        if let head = file.read(0, 8), head[0] == 0x51, head[1] == 0x46, head[2] == 0x49, head[3] == 0xfb {
            // qcow2 (QEMU): the file is as big as what has been written; the disk's size is in the header.
            diskSize = max(1, file.read(24, 8)?.be64(0) ?? fileSize)
            guard let q = Qcow2Source(file: file) else {
                return DiskUsage(usedBytes: min(onMac, diskSize), sizeBytes: diskSize, exact: false, source: "image")
            }
            disk = q
        }
        if let fs = Filesystems.mainFilesystem(disk), fs.total > 0, fs.used <= fs.total, fs.total <= diskSize {
            return DiskUsage(usedBytes: fs.used, sizeBytes: fs.total, exact: true, source: fs.kind)
        }
        return DiskUsage(usedBytes: min(onMac, diskSize), sizeBytes: diskSize, exact: false, source: "image")
    }
}

// MARK: - Byte sources

/// Positioned, bounded, read-only access to a run of bytes: an image file, the disk inside a qcow2 file, a partition.
protocol ByteSource: AnyObject {
    var size: UInt64 { get }
    /// Exactly `length` bytes at `offset`, or nil.
    func read(_ offset: UInt64, _ length: Int) -> [UInt8]?
}

final class FileSource: ByteSource {
    let fd: Int32
    let size: UInt64
    init?(path: String, size: UInt64) {
        fd = open(path, O_RDONLY)
        self.size = size
        if fd < 0 { return nil }
    }
    func close() { _ = Darwin.close(fd) }
    func read(_ offset: UInt64, _ length: Int) -> [UInt8]? {
        guard length > 0, length <= 64 << 20, offset <= size, UInt64(length) <= size - offset else { return nil }
        var buf = [UInt8](repeating: 0, count: length)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(offset)) }
        return n == length ? buf : nil
    }
}

/// A window onto another source: a partition, or a logical volume laid out in pieces.
final class MappedSource: ByteSource {
    struct Piece { var at: UInt64, length: UInt64, baseOffset: UInt64 }
    let base: ByteSource
    let pieces: [Piece]
    let size: UInt64
    init(base: ByteSource, pieces: [Piece]) {
        self.base = base
        self.pieces = pieces.sorted { $0.at < $1.at }
        size = self.pieces.last.map { $0.at + $0.length } ?? 0
    }
    convenience init(base: ByteSource, offset: UInt64, size: UInt64) {
        self.init(base: base, pieces: [Piece(at: 0, length: size, baseOffset: offset)])
    }
    func read(_ offset: UInt64, _ length: Int) -> [UInt8]? {
        guard length > 0, offset <= size, UInt64(length) <= size - offset else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var pos = offset
        let end = offset + UInt64(length)
        while pos < end {
            guard let p = pieces.first(where: { pos >= $0.at && pos < $0.at + $0.length }) else { return nil }
            let n = min(end, p.at + p.length) - pos
            guard let part = base.read(p.baseOffset + (pos - p.at), Int(n)) else { return nil }
            out += part
            pos += n
        }
        return out
    }
}

/// The disk a qcow2 file holds. Clusters that were never written read as zeros. Compressed or encrypted images,
/// and ones that depend on another file, are not read at all.
final class Qcow2Source: ByteSource {
    let file: ByteSource
    let size: UInt64
    private let clusterBits: UInt64
    private let l1: [UInt64]
    private var l2Cache: [UInt64: [UInt8]] = [:]

    init?(file: ByteSource) {
        guard let h = file.read(0, 104) ?? file.read(0, 72), h.be32(0) == 0x514649fb else { return nil }
        let version = h.be32(4)
        guard version == 2 || version == 3 else { return nil }
        let backing = h.be64(8), bits = UInt64(h.be32(20)), crypt = h.be32(32), l1Size = UInt64(h.be32(36)), l1Offset = h.be64(40)
        // Incompatible features this reader does not handle: an external data file (bit 2), compression other than
        // the default (bit 3, harmless unless a cluster is compressed, which is refused below), extended L2 entries (bit 4).
        let incompatible = version == 3 && h.count >= 80 ? h.be64(72) : 0
        guard backing == 0, crypt == 0, incompatible & 0b10100 == 0, bits >= 9, bits <= 21, l1Size > 0, l1Size <= 4 << 20,
              let table = file.read(l1Offset, Int(l1Size * 8)) else { return nil }
        self.file = file
        size = h.be64(24)
        clusterBits = bits
        l1 = (0..<Int(l1Size)).map { table.be64($0 * 8) }
    }

    func read(_ offset: UInt64, _ length: Int) -> [UInt8]? {
        guard length > 0, length <= 64 << 20, offset <= size, UInt64(length) <= size - offset else { return nil }
        let cluster = UInt64(1) << clusterBits, l2Bits = clusterBits - 3
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var pos = offset
        let end = offset + UInt64(length)
        while pos < end {
            let inCluster = pos & (cluster - 1)
            let n = Int(min(end - pos, cluster - inCluster))
            let l1Index = pos >> (clusterBits + l2Bits), l2Index = (pos >> clusterBits) & ((1 << l2Bits) - 1)
            guard l1Index < UInt64(l1.count) else { return nil }
            let l2Offset = l1[Int(l1Index)] & 0x00ff_ffff_ffff_fe00
            var host: UInt64 = 0
            if l2Offset != 0 {
                if l2Cache[l2Offset] == nil {
                    guard let table = file.read(l2Offset, Int(cluster)) else { return nil }
                    if l2Cache.count >= 64 { l2Cache.removeAll() }
                    l2Cache[l2Offset] = table
                }
                let entry = l2Cache[l2Offset]!.be64(Int(l2Index) * 8)
                if entry & (1 << 62) != 0 { return nil } // compressed
                if entry & 1 == 0 { host = entry & 0x00ff_ffff_ffff_fe00 } // bit 0: reads as zeros
            }
            if host == 0 {
                out += [UInt8](repeating: 0, count: n)
            } else {
                guard let part = file.read(host + inCluster, n) else { return nil }
                out += part
            }
            pos += UInt64(n)
        }
        return out
    }
}

// MARK: - Filesystems

enum Filesystems {
    struct Usage { var used: UInt64, total: UInt64, kind: String }

    /// The usage of the disk's main filesystem: the one in its largest partition (or filling the whole disk),
    /// looking inside LVM. Boot, recovery and swap partitions are small and the guest does not count them either.
    static func mainFilesystem(_ disk: ByteSource, depth: Int = 0) -> Usage? {
        if let fs = filesystem(disk) { return fs }
        guard depth < 2 else { return nil }
        if let lv = LVM.largestVolume(disk) { return mainFilesystem(lv, depth: depth + 1) }
        guard let parts = PartitionTable.read(disk), let main = parts.max(by: { $0.size < $1.size }) else { return nil }
        return mainFilesystem(MappedSource(base: disk, offset: main.offset, size: main.size), depth: depth + 1)
    }

    static func filesystem(_ s: ByteSource) -> Usage? {
        APFS.usage(s) ?? Ext.usage(s) ?? Btrfs.usage(s) ?? XFS.usage(s) ?? NTFS.usage(s)
    }
}

enum PartitionTable {
    static func read(_ r: ByteSource) -> [(offset: UInt64, size: UInt64)]? {
        for sector in [UInt64(512), 4096] {
            guard let h = r.read(sector, 92), Array(h[0..<8]) == Array("EFI PART".utf8) else { continue }
            let tableLBA = h.le64(72), count = UInt64(h.le32(80)), entrySize = UInt64(h.le32(84))
            guard entrySize >= 128, count > 0, count <= 256, let table = r.read(tableLBA &* sector, Int(count * entrySize)) else { return nil }
            var out: [(UInt64, UInt64)] = []
            for i in 0..<Int(count) {
                let e = i * Int(entrySize)
                if table[e..<(e + 16)].allSatisfy({ $0 == 0 }) { continue }
                let first = table.le64(e + 32), last = table.le64(e + 40)
                guard last >= first, last < r.size / sector else { return nil }
                out.append((first * sector, (last - first + 1) * sector))
            }
            return out
        }
        // MBR: four primary entries. Extended partitions are not followed; the main filesystem is rarely in one.
        guard let mbr = r.read(0, 512), mbr[510] == 0x55, mbr[511] == 0xaa else { return nil }
        var out: [(UInt64, UInt64)] = []
        for i in 0..<4 {
            let e = 446 + i * 16
            let type = mbr[e + 4], first = UInt64(mbr.le32(e + 8)), count = UInt64(mbr.le32(e + 12))
            guard type != 0, type != 0xee, count > 0, (first + count) * 512 <= r.size else { continue }
            out.append((first * 512, count * 512))
        }
        return out.isEmpty ? nil : out
    }
}

/// macOS guests. The newest checkpoint's space manager says how many blocks the container has and how many are free.
enum APFS {
    static func usage(_ r: ByteSource) -> Filesystems.Usage? {
        guard let sb0 = r.read(0, 4096), sb0.le32(32) == 0x4253584e else { return nil } // "NXSB"
        let bs = UInt64(sb0.le32(36))
        guard bs >= 4096, bs <= 65536, bs & (bs - 1) == 0 else { return nil }
        let descBlocks = sb0.le32(104), descBase = sb0.le64(112)
        // The top bit means the checkpoint area is a tree rather than one run of blocks; not seen on VM disks.
        guard descBlocks & 0x8000_0000 == 0, descBlocks > 0, descBlocks <= 4096,
              let area = r.read(descBase &* bs, Int(UInt64(descBlocks) * bs)) else { return nil }

        // The checkpoint area holds the last few states of the container: superblocks and the maps that say where
        // each state's in-memory objects were written. Newest first, taking the first one that verifies end to end.
        var supers: [(xid: UInt64, at: Int)] = [], maps: [(xid: UInt64, at: Int)] = []
        for i in 0..<Int(descBlocks) {
            let at = i * Int(bs)
            let xid = area.le64(at + 16), type = area.le32(at + 24) & 0xffff
            if area.le32(at + 32) == 0x4253584e, type == 1 { supers.append((xid, at)) }
            else if type == 0xc { maps.append((xid, at)) }
        }
        for sb in supers.sorted(by: { $0.xid > $1.xid }).prefix(4) {
            guard fletcherValid(area, at: sb.at, length: Int(bs)) else { continue }
            let spacemanOID = area.le64(sb.at + 152)
            for map in maps where map.xid == sb.xid {
                guard fletcherValid(area, at: map.at, length: Int(bs)) else { continue }
                let count = Int(area.le32(map.at + 36))
                guard count <= (Int(bs) - 40) / 40 else { continue }
                for k in 0..<count {
                    let e = map.at + 40 + k * 40
                    guard area.le64(e + 24) == spacemanOID else { continue }
                    let paddr = area.le64(e + 32)
                    guard let sm = r.read(paddr &* bs, Int(bs)), fletcherValid(sm, at: 0, length: Int(bs)),
                          sm.le32(24) & 0xffff == 5, sm.le64(16) == sb.xid else { continue }
                    let total = sm.le64(48), free = sm.le64(72)
                    guard total > 0, free <= total, total <= r.size / bs + 1 else { continue }
                    return .init(used: (total - free) * bs, total: total * bs, kind: "APFS")
                }
            }
        }
        return nil
    }

    /// APFS's Fletcher-64 over a block: the first 8 bytes hold the checksum of the rest.
    static func fletcherValid(_ d: [UInt8], at: Int, length: Int) -> Bool {
        guard at >= 0, length >= 16, length % 4 == 0, at + length <= d.count else { return false }
        var s1: UInt64 = 0, s2: UInt64 = 0
        var i = at + 8
        let end = at + length
        while i < end {
            s1 = (s1 + UInt64(d.le32(i))) % 0xffff_ffff
            s2 = (s2 + s1) % 0xffff_ffff
            i += 4
        }
        let c1 = 0xffff_ffff - ((s1 + s2) % 0xffff_ffff)
        let c2 = 0xffff_ffff - ((s1 + c1) % 0xffff_ffff)
        return d.le64(at) == (c2 << 32) | c1
    }
}

/// ext2, ext3 and ext4. Free blocks are summed over the block groups: the superblock's own total is only brought up
/// to date now and then while the filesystem is mounted.
enum Ext {
    static func usage(_ r: ByteSource) -> Filesystems.Usage? {
        guard let sb = r.read(1024, 1024), sb.le16(56) == 0xef53 else { return nil }
        let logBlock = sb.le32(24)
        guard logBlock <= 6 else { return nil }
        let bs = UInt64(1024) << UInt64(logBlock)
        let incompat = sb.le32(96), is64 = incompat & 0x80 != 0
        var blocks = UInt64(sb.le32(4)), sbFree = UInt64(sb.le32(12))
        if is64 { blocks |= UInt64(sb.le32(0x150)) << 32; sbFree |= UInt64(sb.le32(0x158)) << 32 }
        let firstData = UInt64(sb.le32(20)), perGroup = UInt64(sb.le32(32))
        guard blocks > firstData, perGroup > 0, blocks * bs <= r.size + bs else { return nil }
        let kind = incompat & 0x40 != 0 ? "ext4" : (sb.le32(92) & 0x4 != 0 ? "ext3" : "ext2")

        var free = sbFree
        let groups = (blocks - firstData + perGroup - 1) / perGroup
        let descSize = is64 ? max(32, Int(sb.le16(0xfe))) : 32
        // meta_bg (0x10) scatters the descriptors over the disk; then the superblock's total has to do.
        if incompat & 0x10 == 0, groups <= 1 << 20, let table = r.read((firstData + 1) * bs, Int(groups) * descSize) {
            var sum: UInt64 = 0
            for g in 0..<Int(groups) {
                let d = g * descSize
                sum += UInt64(table.le16(d + 12)) | (descSize >= 64 ? UInt64(table.le16(d + 44)) << 16 : 0)
            }
            if sum <= blocks { free = sum }
        }
        guard free <= blocks else { return nil }
        return .init(used: (blocks - free) * bs, total: blocks * bs, kind: kind)
    }
}

/// Btrfs keeps the bytes in use in its superblock, rewritten at every commit (about every 30 seconds).
enum Btrfs {
    static func usage(_ r: ByteSource) -> Filesystems.Usage? {
        guard let sb = r.read(0x10000, 4096), Array(sb[0x40..<0x48]) == Array("_BHRfS_M".utf8) else { return nil }
        let total = sb.le64(0x70), used = sb.le64(0x78)
        guard total > 0, used <= total, total <= r.size else { return nil }
        return .init(used: used, total: total, kind: "Btrfs")
    }
}

/// XFS. Free blocks are summed over the allocation groups, whose headers are written back within seconds; the
/// superblock's own total is only brought up to date at unmount.
enum XFS {
    static func usage(_ r: ByteSource) -> Filesystems.Usage? {
        guard let sb = r.read(0, 512), sb.be32(0) == 0x58465342 else { return nil } // "XFSB"
        let bs = UInt64(sb.be32(4)), blocks = sb.be64(8), agBlocks = UInt64(sb.be32(84)), agCount = UInt64(sb.be32(88))
        let sector = UInt64(sb.be16(102))
        guard bs >= 512, bs <= 65536, blocks > 0, agBlocks > 0, agCount > 0, agCount <= 1 << 16, sector >= 512,
              blocks * bs <= r.size + bs else { return nil }
        var free: UInt64 = 0
        for ag in 0..<agCount {
            guard let agf = r.read(ag * agBlocks * bs + sector, 64), agf.be32(0) == 0x58414746 else { return nil } // "XAGF"
            free += UInt64(agf.be32(52))
        }
        // XFS holds back a small pool of blocks (5% of the disk, at most 8192) that files can never use; the guest
        // does not count it as free either.
        free -= min(free, min(blocks / 20, 8192))
        guard free <= blocks else { return nil }
        return .init(used: (blocks - free) * bs, total: blocks * bs, kind: "XFS")
    }
}

/// NTFS (Windows guests). The clusters in use are the bits set in the volume's allocation bitmap, the file $Bitmap.
enum NTFS {
    static func usage(_ r: ByteSource) -> Filesystems.Usage? {
        guard let boot = r.read(0, 512), Array(boot[3..<11]) == Array("NTFS    ".utf8) else { return nil }
        let bps = UInt64(boot.le16(11)), rawSPC = boot[13]
        let spc: UInt64 = rawSPC > 0x80 ? 1 << UInt64(256 - Int(rawSPC)) : UInt64(rawSPC)
        let sectors = boot.le64(40), mftCluster = boot.le64(48)
        guard bps >= 512, bps <= 4096, spc > 0, sectors > 0, sectors * bps <= r.size + bps else { return nil }
        let cluster = bps * spc, clusters = sectors / spc
        let rawRecord = Int8(bitPattern: boot[64])
        let recordSize = rawRecord < 0 ? 1 << Int(-rawRecord) : Int(rawRecord) * Int(cluster)
        guard recordSize >= 512, recordSize <= 65536, clusters > 0 else { return nil }

        // $Bitmap is file record 6 of the master file table.
        guard var rec = r.read(mftCluster * cluster + 6 * UInt64(recordSize), recordSize), Array(rec[0..<4]) == Array("FILE".utf8) else { return nil }
        // Each sector of a record ends in a check value; the real bytes are kept in the record's fix-up array.
        let usaOffset = Int(rec.le16(4)), usaCount = Int(rec.le16(6))
        guard usaCount >= 1, usaOffset + usaCount * 2 <= recordSize, (usaCount - 1) * 512 <= recordSize else { return nil }
        for i in 1..<usaCount {
            let end = i * 512
            guard rec[end - 2] == rec[usaOffset], rec[end - 1] == rec[usaOffset + 1] else { return nil } // torn write
            rec[end - 2] = rec[usaOffset + i * 2]; rec[end - 1] = rec[usaOffset + i * 2 + 1]
        }
        var at = Int(rec.le16(20))
        while at + 16 <= recordSize {
            let type = rec.le32(at), length = Int(rec.le32(at + 4))
            guard type != 0xffff_ffff, length >= 16, at + length <= recordSize else { break }
            defer { at += length }
            guard type == 0x80, rec[at + 9] == 0 else { continue } // the unnamed data stream
            guard rec[at + 8] == 1, at + 64 <= recordSize else { return nil } // always stored outside the record
            let needed = (clusters + 7) / 8
            guard rec.le64(at + 48) >= needed else { return nil }
            // The stream's location: runs of clusters, each given as a length and a signed step from the last run.
            var p = at + Int(rec.le16(at + 32)), lcn: Int64 = 0, left = needed, used: UInt64 = 0
            while left > 0, p < at + length, rec[p] != 0 {
                let lenBytes = Int(rec[p] & 0xf), offBytes = Int(rec[p] >> 4)
                guard lenBytes > 0, lenBytes <= 8, offBytes <= 8, p + 1 + lenBytes + offBytes <= at + length else { return nil }
                var runLength: UInt64 = 0
                for i in 0..<lenBytes { runLength |= UInt64(rec[p + 1 + i]) << UInt64(8 * i) }
                var step: Int64 = 0
                for i in 0..<offBytes { step |= Int64(rec[p + 1 + lenBytes + i]) << Int64(8 * i) }
                if offBytes > 0, offBytes < 8, rec[p + lenBytes + offBytes] & 0x80 != 0 { step -= Int64(1) << Int64(8 * offBytes) }
                p += 1 + lenBytes + offBytes
                guard offBytes > 0 else { left -= min(left, runLength * cluster); continue } // a hole: nothing in use
                lcn += step
                guard lcn >= 0 else { return nil }
                var runLeft = min(left, runLength * cluster), pos = UInt64(lcn) * cluster
                while runLeft > 0 {
                    let n = min(runLeft, 4 << 20)
                    guard let chunk = r.read(pos, Int(n)) else { return nil }
                    // The last byte may cover clusters past the end of the volume; those bits do not count.
                    let isLast = left == n
                    for (i, byte) in chunk.enumerated() {
                        var b = byte
                        if isLast, i == chunk.count - 1, clusters % 8 != 0 { b &= UInt8((1 << (clusters % 8)) - 1) }
                        used += UInt64(b.nonzeroBitCount)
                    }
                    pos += n; runLeft -= n; left -= n
                }
            }
            guard left == 0, used <= clusters else { return nil }
            return .init(used: used * cluster, total: clusters * cluster, kind: "NTFS")
        }
        return nil
    }
}

/// LVM, which many Linux installers put the root filesystem in. Finds the largest logical volume that lies on this
/// one disk in plain (unstriped) pieces.
enum LVM {
    static func largestVolume(_ disk: ByteSource) -> ByteSource? {
        if let v = volume(inPV: disk) { return v }
        guard let parts = PartitionTable.read(disk) else { return nil }
        return parts.compactMap { volume(inPV: MappedSource(base: disk, offset: $0.offset, size: $0.size)) }.max { $0.size < $1.size }
    }

    static func volume(inPV pv: ByteSource) -> ByteSource? {
        guard let head = pv.read(0, 4096) else { return nil }
        // The label is in one of the first four sectors and points at the header that lists the metadata areas.
        guard let label = (0..<4).map({ $0 * 512 }).first(where: { Array(head[$0..<($0 + 8)]) == Array("LABELONE".utf8) }) else { return nil }
        var p = label + Int(head.le32(label + 20)) + 40 // past the PV's id and size
        while p + 16 <= head.count, head.le64(p) != 0 { p += 16 } // data areas
        p += 16
        guard p + 16 <= head.count else { return nil }
        let mdaOffset = head.le64(p), mdaSize = head.le64(p + 8)
        guard mdaOffset > 0, mdaSize >= 1024, mdaSize <= 64 << 20, let mda = pv.read(mdaOffset, 512),
              Array(mda[4..<20]) == Array(" LVM2 x[5A%r0N*>".utf8) else { return nil }
        let textOffset = mda.le64(40), textSize = mda.le64(48)
        guard textSize > 0, textSize <= 16 << 20, textOffset < mdaSize else { return nil }
        // The metadata is a ring: text that reaches the end of the area continues after its first sector.
        var bytes: [UInt8]
        if textOffset + textSize <= mdaSize {
            guard let t = pv.read(mdaOffset + textOffset, Int(textSize)) else { return nil }
            bytes = t
        } else {
            let first = mdaSize - textOffset
            guard let a = pv.read(mdaOffset + textOffset, Int(first)), let b = pv.read(mdaOffset + 512, Int(textSize - first)) else { return nil }
            bytes = a + b
        }
        guard let root = Config.parse(String(decoding: bytes, as: UTF8.self)),
              let vg = root.sections.first(where: { $0.value.sections["physical_volumes"] != nil })?.value,
              let extentSectors = vg.number("extent_size"), extentSectors > 0,
              let pvs = vg.sections["physical_volumes"]?.sections, pvs.count == 1, let pvName = pvs.keys.first,
              let peStart = pvs[pvName]?.number("pe_start") else { return nil }
        let extent = extentSectors * 512
        var best: [MappedSource.Piece] = [], bestSize: UInt64 = 0
        for (_, lv) in vg.sections["logical_volumes"]?.sections ?? [:] {
            var pieces: [MappedSource.Piece] = [], ok = true
            for (name, seg) in lv.sections where name.hasPrefix("segment") {
                guard let start = seg.number("start_extent"), let count = seg.number("extent_count"),
                      seg.string("type") == "striped", seg.number("stripe_count") == 1,
                      let stripes = seg.arrays["stripes"], stripes.count == 2, stripes[0] == pvName, let onPV = UInt64(stripes[1]) else { ok = false; break }
                pieces.append(.init(at: start * extent, length: count * extent, baseOffset: peStart * 512 + onPV * extent))
            }
            let size = pieces.reduce(0) { $0 + $1.length }
            if ok, size > bestSize { best = pieces; bestSize = size }
        }
        return best.isEmpty ? nil : MappedSource(base: pv, pieces: best)
    }

    /// LVM's metadata text: `key = value` lines, `name { ... }` sections and `[a, b]` lists.
    final class Config {
        var values: [String: String] = [:]
        var arrays: [String: [String]] = [:]
        var sections: [String: Config] = [:]
        func number(_ key: String) -> UInt64? { values[key].flatMap { UInt64($0) } }
        func string(_ key: String) -> String? { values[key] }

        static func parse(_ text: String) -> Config? {
            var tokens: [String] = []
            var i = text.startIndex
            while i < text.endIndex {
                let c = text[i]
                if c == "#" { while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }; continue }
                if c == "\0" { break }
                if c.isWhitespace || c == "," { i = text.index(after: i); continue }
                if "{}[]=".contains(c) { tokens.append(String(c)); i = text.index(after: i); continue }
                if c == "\"" {
                    var j = text.index(after: i)
                    while j < text.endIndex, text[j] != "\"" { j = text.index(after: j) }
                    guard j < text.endIndex else { return nil }
                    tokens.append(String(text[text.index(after: i)..<j])); i = text.index(after: j); continue
                }
                var j = i
                while j < text.endIndex, !text[j].isWhitespace, !"{}[]=,#\"".contains(text[j]) { j = text.index(after: j) }
                tokens.append(String(text[i..<j])); i = j
            }
            var at = 0
            func section() -> Config? {
                let out = Config()
                while at < tokens.count, tokens[at] != "}" {
                    let key = tokens[at]; at += 1
                    guard at < tokens.count else { return nil }
                    if tokens[at] == "{" {
                        at += 1
                        guard let inner = section(), at < tokens.count, tokens[at] == "}" else { return nil }
                        at += 1
                        out.sections[key] = inner
                    } else if tokens[at] == "=" {
                        at += 1
                        guard at < tokens.count else { return nil }
                        if tokens[at] == "[" {
                            at += 1
                            var list: [String] = []
                            while at < tokens.count, tokens[at] != "]" { list.append(tokens[at]); at += 1 }
                            guard at < tokens.count else { return nil }
                            at += 1
                            out.arrays[key] = list
                        } else { out.values[key] = tokens[at]; at += 1 }
                    } else { return nil }
                }
                return out
            }
            let root = section()
            return at == tokens.count ? root : nil
        }
    }
}

extension Array where Element == UInt8 {
    func le16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func le32(_ i: Int) -> UInt32 { UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24 }
    func le64(_ i: Int) -> UInt64 { UInt64(le32(i)) | UInt64(le32(i + 4)) << 32 }
    func be16(_ i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func be32(_ i: Int) -> UInt32 { UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3]) }
    func be64(_ i: Int) -> UInt64 { UInt64(be32(i)) << 32 | UInt64(be32(i + 4)) }
}
