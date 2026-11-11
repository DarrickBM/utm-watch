import CSysShim
import Foundation

/// Links a VM process to its `.utm` bundle through the files it holds open (disk image, auxiliary storage).
public enum ProcessVMMatcher {
    /// "/a/b/macOS 26 B.utm/Data/x.img" -> "/a/b/macOS 26 B.utm"
    public static func utmBundlePath(fromOpenPath path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let idx = components.firstIndex(where: { $0.hasSuffix(".utm") }) else { return nil }
        return components[...idx].joined(separator: "/")
    }

    private final class PathBox { var paths: [String] = [] }

    public static func openPaths(pid: Int32) -> [String] {
        let box = PathBox()
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        _ = shim_proc_open_paths(pid, { cPath, ctx in
            guard let cPath, let ctx else { return }
            Unmanaged<PathBox>.fromOpaque(ctx).takeUnretainedValue().paths.append(String(cString: cPath))
        }, ctx)
        return box.paths
    }

    /// The bundle URL this process belongs to, if any of its open files live inside a `.utm` package.
    public static func bundleURL(pid: Int32) -> URL? { bundleURL(fromOpenPaths: openPaths(pid: pid)) }

    public static func bundleURL(fromOpenPaths paths: [String]) -> URL? {
        for path in paths {
            if let bundle = utmBundlePath(fromOpenPath: path) {
                return URL(fileURLWithPath: bundle, isDirectory: true)
            }
        }
        return nil
    }

    /// Folders other VM tools keep their disk images in. First match wins, so Colima and Rancher Desktop,
    /// which both nest a Lima folder, come before Lima.
    private static let otherApps: [(marker: String, name: String)] = [
        ("/com.docker.docker/", "Docker Desktop"),
        ("/.orbstack/", "OrbStack"),
        ("/.tart/", "Tart"),
        ("/.lume/", "Lume"),
        ("/.colima/", "Colima"),
        ("/rancher-desktop/", "Rancher Desktop"),
        ("/containers/podman/", "Podman"),
        ("/.lima/", "Lima"),
    ]

    /// "/Users/d/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" -> "Docker Desktop"
    public static func otherApp(fromOpenPath path: String) -> String? {
        otherApps.first { path.contains($0.marker) }?.name
    }

    /// The app a VM process outside UTM belongs to, judged by the files it holds open.
    public static func otherApp(fromOpenPaths paths: [String]) -> String? {
        for path in paths { if let name = otherApp(fromOpenPath: path) { return name } }
        return nil
    }
}
