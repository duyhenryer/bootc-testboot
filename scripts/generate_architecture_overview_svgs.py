#!/usr/bin/env python3
"""Emit SVG diagrams for docs/project/001-architecture-overview.md (tldraw-style layout)."""
from __future__ import annotations

import os

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "docs",
    "images",
    "project",
    "architecture",
)

MARKER = """
  <defs>
    <marker id="arrow" markerWidth="10" markerHeight="10" refX="9" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#334155"/>
    </marker>
  </defs>
"""


def esc(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def svg_open(w: int, h: int) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
        'font-family="system-ui,Segoe UI,sans-serif" font-size="13">'
        + MARKER
    )


def svg_close() -> str:
    return "</svg>"


def rect_round(x: float, y: float, w: float, h: float, fill: str, stroke: str, label: str, fs: int = 12) -> str:
    t = esc(label)
    lines = t.split("\n")
    return (
        f'<g><rect x="{x}" y="{y}" rx="6" ry="6" width="{w}" height="{h}" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>'
        f'<text x="{x + w/2}" y="{y + h/2 + (len(lines)-1)*fs*0.35}" text-anchor="middle" fill="#0f172a" font-size="{fs}">'
        + "".join(
            f'<tspan x="{x + w/2}" dy="{0 if i==0 else fs}" text-anchor="middle">{line}</tspan>'
            for i, line in enumerate(lines)
        )
        + "</text></g>"
    )


def ellipse_node(x: float, y: float, rx: float, ry: float, fill: str, stroke: str, label: str) -> str:
    cx, cy = x + rx, y + ry
    t = esc(label)
    return (
        f'<g><ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>'
        f'<text x="{cx}" y="{cy+4}" text-anchor="middle" fill="#0f172a" font-size="12">{t}</text></g>'
    )


def frame(x: float, y: float, w: float, h: float, title: str, fill: str = "#f8fafc") -> str:
    return (
        f'<rect x="{x}" y="{y}" rx="8" ry="8" width="{w}" height="{h}" '
        f'fill="{fill}" stroke="#64748b" stroke-width="1.2" stroke-dasharray="4 3"/>'
        f'<text x="{x+10}" y="{y+18}" fill="#334155" font-size="12" font-weight="600">{esc(title)}</text>'
    )


def arrow_line(x1: float, y1: float, x2: float, y2: float, dashed: bool = False) -> str:
    dash = 'stroke-dasharray="6 4"' if dashed else ""
    return (
        f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="#334155" stroke-width="1.5" '
        f'marker-end="url(#arrow)" {dash}/>'
    )


def path_arrow(d: str, dashed: bool = False) -> str:
    dash = 'stroke-dasharray="6 4"' if dashed else ""
    return (
        f'<path d="{d}" fill="none" stroke="#334155" stroke-width="1.5" '
        f'marker-end="url(#arrow)" {dash}/>'
    )


def text_label(x: float, y: float, s: str, size: int = 11) -> str:
    return f'<text x="{x}" y="{y}" fill="#475569" font-size="{size}">{esc(s)}</text>'


def write(name: str, body: str) -> None:
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(body)
    print("wrote", path)


def diagram_1() -> str:
    W, H = 640, 900
    parts = [svg_open(W, H)]
    parts.append(frame(24, 16, 592, 248, "Single Containerfile"))
    parts.append(rect_round(48, 44, 544, 36, "#dbeafe", "#2563eb", "Linux kernel (/usr/lib/modules)"))
    parts.append(rect_round(48, 88, 544, 36, "#dbeafe", "#2563eb", "Userspace (systemd, nginx, packages)"))
    parts.append(rect_round(48, 132, 544, 36, "#dbeafe", "#2563eb", "Apps (Go binaries, systemd units via rootfs)"))
    parts.append(rect_round(48, 176, 544, 36, "#dbeafe", "#2563eb", "Configs (nginx.conf, sshd, etc. via rootfs)"))
    parts.append(frame(24, 280, 592, 88, "Build Time", "#f0fdf4"))
    parts.append(rect_round(200, 312, 240, 44, "#bbf7d0", "#16a34a", "OCI Image"))
    parts.append(arrow_line(320, 264, 320, 312))
    parts.append(frame(24, 388, 592, 100, "Registry (GHCR)", "#fffbeb"))
    parts.append(ellipse_node(200, 416, 120, 36, "#fde68a", "#d97706", "GitHub Container Registry"))
    parts.append(arrow_line(320, 356, 320, 416))
    parts.append(frame(24, 500, 592, 120, "bootc-image-builder", "#faf5ff"))
    parts.append(rect_round(80, 536, 200, 44, "#e9d5ff", "#7c3aed", "AMI (AWS)"))
    parts.append(rect_round(360, 536, 200, 44, "#e9d5ff", "#7c3aed", "VMDK / OVA (VMware)"))
    parts.append(arrow_line(320, 488, 320, 500))
    parts.append(arrow_line(320, 488, 180, 536))
    parts.append(arrow_line(320, 488, 460, 536))
    parts.append(frame(24, 636, 592, 248, "Runtime", "#fef2f2"))
    parts.append(rect_round(60, 676, 200, 40, "#fecaca", "#dc2626", "EC2 Instance"))
    parts.append(rect_round(380, 676, 200, 40, "#fecaca", "#dc2626", "vSphere VM"))
    parts.append(rect_round(220, 740, 200, 40, "#fecaca", "#dc2626", "systemd as pid1"))
    parts.append(rect_round(220, 820, 200, 44, "#fecaca", "#dc2626", "OSTree deployment root"))
    parts.append(arrow_line(320, 580, 320, 636))
    parts.append(arrow_line(160, 716, 270, 740))
    parts.append(arrow_line(480, 716, 370, 740))
    parts.append(arrow_line(320, 780, 320, 820))
    parts.append(svg_close())
    return "".join(parts)


def diagram_2() -> str:
    W, H = 1240, 280
    y0 = 20
    parts = [svg_open(W, H)]
    parts.append(frame(12, y0, 188, 210, "Source"))
    parts.append(rect_round(28, y0 + 28, 156, 44, "#e0f2fe", "#0284c7", "repos/hello/\nrepos/api/"))
    parts.append(rect_round(28, y0 + 80, 156, 36, "#e0f2fe", "#0284c7", "Containerfile"))
    parts.append(rect_round(28, y0 + 124, 156, 36, "#e0f2fe", "#0284c7", "base/rootfs/"))
    x1 = 216
    parts.append(frame(x1, y0, 200, 210, "App Build"))
    parts.append(rect_round(x1 + 16, y0 + 72, 168, 36, "#ccfbf1", "#0d9488", "make apps"))
    parts.append(rect_round(x1 + 16, y0 + 124, 168, 36, "#ccfbf1", "#0d9488", "output/bin/"))
    parts.append(arrow_line(200, y0 + 50, x1, y0 + 90))
    parts.append(arrow_line(x1 + 100, y0 + 108, x1 + 100, y0 + 124))
    x2 = 432
    parts.append(frame(x2, y0, 248, 210, "OS Build"))
    parts.append(rect_round(x2 + 20, y0 + 28, 208, 36, "#dcfce7", "#16a34a", "OCI Image"))
    parts.append(rect_round(x2 + 16, y0 + 120, 216, 44, "#dcfce7", "#16a34a", "podman build"))
    parts.append(arrow_line(x2 + 124, y0 + 64, x2 + 124, y0 + 120))
    parts.append(arrow_line(416, y0 + 90, x2 + 16, y0 + 132))
    parts.append(arrow_line(416, y0 + 50, x2 + 80, y0 + 120))
    parts.append(arrow_line(416, y0 + 142, x2 + 80, y0 + 120))
    parts.append(text_label(x2 + 50, y0 + 108, "COPY", 10))
    x3 = 696
    parts.append(frame(x3, y0, 160, 120, "Push"))
    parts.append(ellipse_node(x3 + 8, y0 + 40, 72, 32, "#fef3c7", "#d97706", "GHCR"))
    parts.append(arrow_line(x2 + 248, y0 + 50, x3, y0 + 72))
    x4 = 872
    parts.append(frame(x4, y0, 172, 210, "Bake"))
    parts.append(rect_round(x4 + 12, y0 + 36, 148, 36, "#ede9fe", "#7c3aed", "bootc-image-builder"))
    parts.append(rect_round(x4 + 12, y0 + 84, 68, 32, "#ede9fe", "#7c3aed", "AMI"))
    parts.append(rect_round(x4 + 96, y0 + 84, 64, 32, "#ede9fe", "#7c3aed", "VMDK"))
    parts.append(rect_round(x4 + 56, y0 + 132, 60, 28, "#ede9fe", "#7c3aed", "OVA"))
    parts.append(arrow_line(x3 + 80, y0 + 72, x4 + 12, y0 + 54))
    parts.append(arrow_line(x4 + 46, y0 + 72, x4 + 46, y0 + 84))
    parts.append(arrow_line(x4 + 128, y0 + 72, x4 + 128, y0 + 84))
    parts.append(arrow_line(x4 + 128, y0 + 116, x4 + 86, y0 + 132))
    x5 = 1064
    parts.append(frame(x5, y0, 168, 210, "Deploy"))
    parts.append(ellipse_node(x5 + 12, y0 + 36, 72, 30, "#fecdd3", "#e11d48", "EC2 Instance"))
    parts.append(ellipse_node(x5 + 12, y0 + 120, 72, 30, "#fecdd3", "#e11d48", "vSphere VM"))
    parts.append(arrow_line(x4 + 46, y0 + 116, x5 + 48, y0 + 66))
    parts.append(arrow_line(x4 + 86, y0 + 160, x5 + 48, y0 + 150))
    parts.append(svg_close())
    return "".join(parts)


def diagram_3() -> str:
    W, H = 920, 400
    parts = [svg_open(W, H)]
    parts.append(frame(16, 16, 420, 160, "Source (repo)"))
    parts.append(rect_round(32, 44, 388, 32, "#e0f2fe", "#0284c7", "bootc/libs/common/rootfs/"))
    parts.append(rect_round(32, 84, 388, 32, "#e0f2fe", "#0284c7", "bootc/services/*/rootfs/"))
    parts.append(rect_round(32, 124, 388, 32, "#e0f2fe", "#0284c7", "bootc/apps/*/rootfs/"))
    parts.append(frame(16, 200, 888, 180, "Image / VM (runtime)"))
    parts.append(rect_round(48, 232, 240, 36, "#f1f5f9", "#475569", "/usr/libexec/testboot/*.sh"))
    parts.append(rect_round(48, 280, 240, 36, "#f1f5f9", "#475569", "/usr/share/mongodb/ valkey/ nginx/"))
    parts.append(rect_round(48, 328, 240, 36, "#f1f5f9", "#475569", "/etc/*.conf symlinks"))
    parts.append(rect_round(340, 232, 240, 36, "#f1f5f9", "#475569", "/usr/lib/systemd/system/"))
    parts.append(rect_round(340, 280, 240, 36, "#f1f5f9", "#475569", "/usr/lib/tmpfiles.d/"))
    parts.append(rect_round(340, 328, 240, 36, "#f1f5f9", "#475569", "/usr/lib/sysusers.d/"))
    parts.append(rect_round(632, 232, 240, 36, "#f1f5f9", "#475569", "/etc/yum.repos.d/"))
    parts.append(text_label(24, 192, "COPY / (representative flows)", 11))
    parts.append(arrow_line(220, 60, 168, 232))
    parts.append(arrow_line(220, 100, 168, 280))
    parts.append(arrow_line(220, 100, 168, 328))
    parts.append(arrow_line(220, 140, 460, 232))
    parts.append(arrow_line(220, 140, 460, 280))
    parts.append(arrow_line(220, 140, 460, 328))
    parts.append(arrow_line(220, 140, 752, 232))
    parts.append(path_arrow("M 168 298 C 400 360 500 280 752 250", dashed=True))
    parts.append(text_label(400, 340, "ln -sf", 10))
    parts.append(svg_close())
    return "".join(parts)


def diagram_4() -> str:
    W, H = 520, 520
    parts = [svg_open(W, H)]
    parts.append(frame(16, 16, 488, 120, "READ-ONLY (composefs)", "#eff6ff"))
    parts.append(rect_round(40, 48, 440, 36, "#bfdbfe", "#2563eb", "/usr (OS, binaries, configs)"))
    parts.append(rect_round(40, 92, 440, 32, "#bfdbfe", "#2563eb", "/opt (if used)"))
    parts.append(frame(16, 152, 488, 100, "MUTABLE", "#fff7ed"))
    parts.append(rect_round(40, 184, 440, 32, "#fed7aa", "#ea580c", "/etc (3-way merge on upgrade)"))
    parts.append(rect_round(40, 220, 440, 24, "#fed7aa", "#ea580c", "/var (persistent, NOT rolled back)", 11))
    parts.append(frame(16, 268, 488, 72, "Build-time", "#f0fdf4"))
    parts.append(rect_round(40, 296, 440, 32, "#bbf7d0", "#16a34a", "Everything mutable for derivation"))
    parts.append(frame(16, 352, 488, 152, "Runtime (deployed)", "#fef2f2"))
    parts.append(rect_round(40, 384, 200, 32, "#fecaca", "#dc2626", "/usr"))
    parts.append(rect_round(264, 384, 200, 32, "#fecaca", "#dc2626", "/opt"))
    parts.append(rect_round(40, 428, 200, 32, "#fecaca", "#dc2626", "/etc"))
    parts.append(rect_round(264, 428, 200, 32, "#fecaca", "#dc2626", "/var"))
    parts.append(svg_close())
    return "".join(parts)


def diagram_5() -> str:
    W, H = 980, 260
    parts = [svg_open(W, H)]
    parts.append(text_label(16, 28, "Upgrade lifecycle (equivalent to stateDiagram-v2)", 13))
    parts.append('<circle cx="36" cy="120" r="8" fill="#334155"/>')
    parts.append(arrow_line(44, 120, 92, 120))
    parts.append(text_label(48, 108, "Boot", 10))
    parts.append(rect_round(92, 96, 96, 48, "#e0e7ff", "#4f46e5", "Running"))
    parts.append(arrow_line(188, 120, 228, 120))
    parts.append(text_label(190, 108, "--download-only", 9))
    parts.append(rect_round(228, 96, 118, 48, "#e0e7ff", "#4f46e5", "DownloadOnly"))
    parts.append(arrow_line(346, 120, 386, 120))
    parts.append(text_label(348, 108, "downloaded", 9))
    parts.append(rect_round(386, 96, 88, 48, "#e0e7ff", "#4f46e5", "Staged"))
    parts.append(path_arrow("M 430 144 C 360 200 240 200 188 120"))
    parts.append(text_label(220, 200, "No reboot yet", 10))
    parts.append(arrow_line(474, 120, 514, 120))
    parts.append(text_label(476, 108, "--apply", 9))
    parts.append(rect_round(514, 96, 88, 48, "#e0e7ff", "#4f46e5", "Apply"))
    parts.append(arrow_line(602, 120, 642, 120))
    parts.append(text_label(604, 108, "bootloader", 9))
    parts.append(rect_round(642, 96, 96, 48, "#e0e7ff", "#4f46e5", "Reboot"))
    parts.append(arrow_line(738, 120, 780, 120))
    parts.append(text_label(740, 108, "active", 9))
    parts.append('<circle cx="800" cy="120" r="12" fill="none" stroke="#334155" stroke-width="2"/>')
    parts.append('<circle cx="800" cy="120" r="5" fill="#334155"/>')
    parts.append(svg_close())
    return "".join(parts)


def diagram_6() -> str:
    W, H = 720, 260
    parts = [svg_open(W, H)]
    parts.append(frame(16, 16, 200, 200, "Repository"))
    parts.append(rect_round(40, 48, 152, 36, "#e0f2fe", "#0284c7", "repos/hello/"))
    parts.append(rect_round(40, 96, 152, 36, "#e0f2fe", "#0284c7", "repos/newapp/"))
    parts.append(frame(240, 16, 280, 200, "Container Image"))
    parts.append(rect_round(260, 52, 120, 32, "#dcfce7", "#16a34a", "/usr/bin/hello"))
    parts.append(rect_round(400, 52, 104, 32, "#dcfce7", "#16a34a", "hello.service"))
    parts.append(rect_round(260, 96, 120, 32, "#dcfce7", "#16a34a", "hello-tmpfiles.conf"))
    parts.append(rect_round(260, 140, 120, 32, "#dcfce7", "#16a34a", "/usr/bin/newapp"))
    parts.append(rect_round(400, 140, 104, 32, "#dcfce7", "#16a34a", "newapp.service"))
    parts.append(frame(540, 16, 164, 120, "Runtime"))
    parts.append(rect_round(556, 52, 132, 40, "#fee2e2", "#dc2626", "nginx"))
    parts.append(arrow_line(216, 64, 260, 68))
    parts.append(arrow_line(216, 64, 400, 68))
    parts.append(arrow_line(216, 112, 260, 112))
    parts.append(arrow_line(216, 156, 260, 156))
    parts.append(arrow_line(216, 156, 400, 156))
    parts.append(arrow_line(452, 72, 556, 72))
    parts.append(arrow_line(452, 156, 556, 72))
    parts.append(svg_close())
    return "".join(parts)


def diagram_7() -> str:
    W, H = 560, 380
    parts = [svg_open(W, H)]
    parts.append(frame(16, 16, 528, 100, "Current POC", "#eff6ff"))
    parts.append(rect_round(40, 44, 140, 32, "#bfdbfe", "#2563eb", "hello service"))
    parts.append(rect_round(200, 44, 120, 32, "#bfdbfe", "#2563eb", "nginx"))
    parts.append(rect_round(340, 44, 120, 32, "#bfdbfe", "#2563eb", "cloud-init"))
    parts.append(frame(16, 132, 528, 140, "Full Stack", "#f0fdf4"))
    parts.append(rect_round(32, 164, 120, 28, "#bbf7d0", "#16a34a", "nginx (reverse proxy)"))
    parts.append(rect_round(164, 164, 80, 28, "#bbf7d0", "#16a34a", "valkey"))
    parts.append(rect_round(260, 164, 90, 28, "#bbf7d0", "#16a34a", "rabbitmq"))
    parts.append(rect_round(32, 204, 80, 28, "#bbf7d0", "#16a34a", "app-api"))
    parts.append(rect_round(124, 204, 100, 28, "#bbf7d0", "#16a34a", "app-worker"))
    parts.append(rect_round(236, 204, 80, 28, "#bbf7d0", "#16a34a", "app-web"))
    parts.append(frame(16, 288, 528, 76, "Deployment Targets", "#faf5ff"))
    parts.append(rect_round(40, 316, 100, 32, "#e9d5ff", "#7c3aed", "AWS AMI"))
    parts.append(rect_round(156, 316, 110, 32, "#e9d5ff", "#7c3aed", "VMware OVA"))
    parts.append(rect_round(282, 316, 90, 32, "#e9d5ff", "#7c3aed", "QCOW2"))
    parts.append(rect_round(388, 316, 80, 32, "#e9d5ff", "#7c3aed", "ISO"))
    parts.append(arrow_line(280, 116, 280, 132))
    parts.append(arrow_line(280, 272, 280, 288))
    parts.append(svg_close())
    return "".join(parts)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    write("001-system-architecture.svg", diagram_1())
    write("002-build-pipeline.svg", diagram_2())
    write("003-rootfs-overlay.svg", diagram_3())
    write("004-filesystem-model.svg", diagram_4())
    write("005-upgrade-lifecycle.svg", diagram_5())
    write("006-app-deployment.svg", diagram_6())
    write("007-production-vision.svg", diagram_7())


if __name__ == "__main__":
    main()
