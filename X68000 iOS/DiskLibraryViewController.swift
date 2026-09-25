//
//  DiskLibraryViewController.swift
//  MPX68K for iOS
//
//  Lists the disk images in Documents/MPX68K so a disk can be inserted or
//  swapped with one tap (multi-disk games), plus "ほかの場所から…" to import
//  images with the document picker.
//

import UIKit

final class DiskLibraryViewController: UITableViewController {

    enum Kind {
        case floppy
        case hardDisk

        var extensions: Set<String> {
            switch self {
            case .floppy: return ["dim", "xdf", "2hd", "d88", "hdm"]
            case .hardDisk: return ["hdf", "hds"]
            }
        }
    }

    private let kind: Kind
    private let mountedURL: URL?
    private let onSelect: (URL) -> Void
    private let onImport: () -> Void
    private var disks: [URL] = []

    init(title: String, kind: Kind, mountedURL: URL?,
         onSelect: @escaping (URL) -> Void, onImport: @escaping () -> Void) {
        self.kind = kind
        self.mountedURL = mountedURL?.standardizedFileURL
        self.onSelect = onSelect
        self.onImport = onImport
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Documents/MPX68K, where ROMs and disk images live.
    static var libraryFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MPX68K", isDirectory: true)
    }

    static func diskImages(of kind: Kind) -> [URL] {
        guard let folder = libraryFolder,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { kind.extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        disks = Self.diskImages(of: kind)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? disks.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "このアプリのディスク" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0, disks.isEmpty else { return nil }
        return "「ファイル」アプリの「このiPhone内」→「MPX68K for iOS」→「MPX68K」にディスクイメージを置くか、下の「ほかの場所から…」で取り込めます。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            let url = disks[indexPath.row]
            content.text = url.lastPathComponent
            content.image = UIImage(systemName: kind == .floppy ? "square.fill" : "externaldrive")
            cell.accessoryType = (url.standardizedFileURL == mountedURL) ? .checkmark : .none
        } else {
            content.text = "ほかの場所から…"
            content.image = UIImage(systemName: "folder")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let url = disks[indexPath.row]
            dismiss(animated: true) { self.onSelect(url) }
        } else {
            dismiss(animated: true) { self.onImport() }
        }
    }
}
