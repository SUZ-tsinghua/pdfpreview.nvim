"""Check native raster, Metal composition and vector refinement pixels."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def fixture(path, content, crop=False):
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 >>"]
    for rotation in (0, 90, 180, 270):
        box = "/CropBox [40 60 360 540]" if crop else ""
        objects.append((f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] {box} "
                        f"/Rotate {rotation} /Resources << /Font << /F1 8 0 R >> >> /Contents 7 0 R >>").encode())
    objects.append(f"<< /Length {len(content)} >>\nstream\n".encode() + content + b"\nendstream")
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    data, offsets = b"%PDF-1.4\n", [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{index} 0 obj\n".encode() + obj + b"\nendobj\n"
    start = len(data)
    data += f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode()
    data += b"".join(f"{offset:010} 00000 n \n".encode() for offset in offsets[1:])
    data += f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()
    path.write_bytes(data)


class Worker:
    def __init__(self, path):
        self.process = subprocess.Popen([str(ROOT / '.build/pdfpreview-native'), str(path)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.serial = 0

    def request(self, **values):
        self.serial += 1
        self.process.stdin.write(json.dumps(dict(id=self.serial, **values)) + '\n')
        self.process.stdin.flush()
        result = json.loads(self.process.stdout.readline())
        assert result['id'] == self.serial
        if 'error' not in result:
            assert result.get('cache_bytes', 0) + result.get('gpu_cache_bytes', 0) <= 128 * 1024 * 1024
            assert result.get('output_cache_bytes', 0) <= 64 * 1024 * 1024
        return result

    def checked(self, **values):
        result = self.request(**values)
        assert 'error' not in result, result
        return result

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=10) == 0



def pixels(path, width, height):
    return np.frombuffer(path.read_bytes(), dtype=np.uint8).reshape(height, width, 4)


def check_rasters(directory, pdf):
    with Worker(pdf) as worker:
        info = worker.checked(action='info')
        assert info['protocol'] == 1
        assert [(p['width'], p['height']) for p in info['pages']] == [(320, 480), (480, 320)] * 2
        raw, png, crop = [directory / name for name in ['raw.rgba', 'page.png', 'crop.rgba']]
        for page in range(1, 5):
            common = dict(page=page, px=600, py=800, x=0, y=0, width=600, height=800)
            worker.checked(**common, file=str(raw), format=32)
            worker.checked(**common, file=str(png), format=100)
            assert np.array_equal(pixels(raw, 600, 800), np.asarray(Image.open(png).convert('RGBA')))
            worker.checked(**dict(common, x=119, y=213, width=241, height=173), file=str(crop), format=32)
            assert np.array_equal(pixels(crop, 241, 173), pixels(raw, 600, 800)[213:386, 119:360])
            stem = directory / 'poppler'
            subprocess.run(['pdftoppm', '-f', str(page), '-l', str(page), '-singlefile', '-cropbox',
                            '-scale-dimension-before-rotation', '-png', '-scale-to-x', '600', '-scale-to-y',
                            '800', str(pdf), str(stem)], check=True, capture_output=True, timeout=15)
            reference = np.asarray(Image.open(str(stem) + '.png').convert('RGBA'), dtype=np.int16)
            assert np.abs(pixels(raw, 600, 800).astype(np.int16) - reference).mean() < 2
            region = dict(page=page, px=2100, py=2800, x=987, y=1001, width=1101, height=1081,
                          format=32, file=str(crop))
            worker.checked(**region, cache=True)
            cached = pixels(crop, 1101, 1081).copy()
            worker.checked(**region, cache=False)
            assert np.abs(cached.astype(np.int16) - pixels(crop, 1101, 1081).astype(np.int16)).max() <= 1
        assert 'error' in worker.request(page=-1, file=str(raw))
        assert 'pages' in worker.checked(action='info'), 'Invalid requests do not corrupt the protocol'
    print('PASS: rotated CropBox, RGBA/PNG channels, Poppler agreement and source-tile seams')


def check_metal(directory, pdf):
    with Worker(pdf) as worker, Worker(pdf) as reference:
        if not worker.checked(action='info')['surface']:
            print('SKIP: Metal pixel checks require an accessible unified-memory device')
            return
        output, expected_file = directory / 'slot.rgba', directory / 'reference.rgba'
        page = dict(page=1, px=384, py=512, left=-23.3, top=-34.75, width=468.48, height=624.64)
        def compose(target, file, width=371, height=259, pages=None):
            return target.checked(action='compose', height=height, pages=pages or [page],
                                  parts=[dict(width=width, offset=0, file=str(file))])
        # Fresh-worker pixels must agree after each mapped-file lifetime change.
        for mutation in ['initial', 'reuse', 'truncate', 'replace', 'unlink', 'resize']:
            width, height = (321, 247) if mutation == 'resize' else (371, 259)
            if mutation == 'truncate':
                output.write_bytes(b'!')
            elif mutation == 'replace':
                other = directory / 'new-inode.rgba'
                other.write_bytes(b'\0' * output.stat().st_size)
                other.replace(output)
            elif mutation == 'unlink':
                output.unlink()
            compose(worker, output, width, height)
            compose(reference, expected_file, width, height)
            assert output.read_bytes() == expected_file.read_bytes(), mutation
        # Independent affine reference checks scale, orientation and clipping.
        source = directory / 'source.rgba'
        reference.checked(page=1, px=384, py=512, x=0, y=0, width=384, height=512,
                          format=32, file=str(source), cache=False)
        source_image = Image.frombytes('RGBA', (384, 512), source.read_bytes())
        width, height, scale = 247, 193, 1.22
        expected = Image.new('RGBA', (width, height), (32, 36, 44, 255))
        warped = source_image.transform((width, height), Image.Transform.AFFINE,
                  (1/scale, 0, -page['left']/scale, 0, 1/scale, -page['top']/scale),
                  Image.Resampling.BILINEAR, fillcolor=(0, 0, 0, 0))
        expected.alpha_composite(warped)
        reply = compose(worker, output, width, height)
        actual = pixels(output, width, height).copy()
        delta = np.abs(actual.astype(np.int16) - np.asarray(expected, dtype=np.int16))
        assert delta.mean() < 3 and np.percentile(delta, 95) <= 2
        assert reply['cache_bytes'] == 0, 'GPU sources release CPU staging pixels'
        parts = [directory / 'stripe-0.rgba', directory / 'stripe-1.rgba']
        worker.checked(action='compose', height=height, pages=[page],
                       parts=[dict(width=88, offset=0, file=str(parts[0])),
                              dict(width=159, offset=88, file=str(parts[1]))])
        joined = np.concatenate([pixels(parts[0], 88, height), pixels(parts[1], 159, height)], axis=1)
        assert np.abs(joined.astype(np.int16) - actual.astype(np.int16)).max() <= 1
        # Evict output mappings and source textures while preserving exact pixels.
        original = None
        for slot in [0, 1, 2, 0]:
            path = directory / f'large-{slot}.rgba'
            compose(worker, path, 4000, 2000)
            value = hashlib.sha256(path.read_bytes()).hexdigest()
            original = original or value
            assert value == original, 'Output eviction preserves pixels'
        original = None
        for number in [1, 2, 3, 1]:
            large = dict(page, page=number, px=4096, py=4096, width=64, height=64)
            compose(worker, output, 64, 32, [large])
            if number == 1:
                value = output.read_bytes()
                original = original or value
                assert value == original, 'Source eviction preserves pixels'
        part = dict(width=8, offset=0, file=str(output))
        assert 'error' in worker.request(action='compose', height=8, pages=[page], parts=[part, part])
        compose(worker, output, 8, 8)
    print('PASS: Metal affine pixels, stripes, file identity, source/output cache bounds and recovery')


with tempfile.TemporaryDirectory(prefix='pdfpreview-refine-pixels-') as directory:
    directory = Path(directory)
    pdf = directory / 'rotated vectors.pdf'
    content = (b'1 0 0 rg 40 60 120 200 re f\n0 1 0 rg 240 60 120 200 re f\n'
               b'0 0 1 rg 40 340 120 200 re f\n0.8 0.4 0 rg 240 340 120 200 re f\n'
               b'0 0 0 rg BT /F1 9 Tf 65 330 Td (Direct viewport vector text) Tj ET\n'
               b'0.3 w 0 0 0 RG 30 300 m 120 580 240 20 370 300 c S\n')
    fixture(pdf, content, crop=True)
    check_rasters(directory, pdf)
    check_metal(directory, pdf)
    worker = Worker(pdf)
    try:
        info = worker.request(action='info')
        assert info['protocol'] == 1, 'Worker and client share one protocol'
        unused = directory / 'invalid.rgba'
        valid_page = dict(page=1, width=1200, height=1800, left=-119, top=-213)
        for invalid in [dict(height=-1, pages=[], parts=[]),
                        dict(height=10, pages=[{}], parts=[dict(width=10, offset=0, file=str(unused))]),
                        dict(height=10, pages=[valid_page], parts=[dict(width=10, offset=0, file=str(unused))]*2),
                        dict(height=8192, pages=[valid_page], parts=[dict(width=8192, offset=0, file=str(unused))])]:
            assert 'error' in worker.request(action='refine', **invalid)
            assert not unused.exists(), 'Invalid complete requests allocate no output'
        for page in range(1, 5):
            width, height = 531, 323
            direct, refined = directory / 'direct.rgba', directory / 'refined.rgba'
            assert 'error' not in worker.request(page=page, px=1200, py=1800, x=119, y=213,
                                                width=width, height=height, format=32, file=str(direct), cache=False)
            reply = worker.request(action='refine', height=height,
                                   pages=[dict(valid_page, page=page)],
                                   parts=[dict(width=width, offset=0, file=str(refined))])
            assert 'error' not in reply, reply
            a = np.frombuffer(direct.read_bytes(), dtype=np.uint8)
            b = np.frombuffer(refined.read_bytes(), dtype=np.uint8)
            diff = np.abs(a.astype(np.int16) - b.astype(np.int16))
            assert diff.max() <= 1 and diff.mean() < .001, (page, diff.max(), diff.mean())
            assert reply['cache_bytes'] == reply['gpu_cache_bytes'] == reply['output_cache_bytes'] == 0

        # Fractional geometry, page gaps and adjacent output stripes must agree.
        pages = [dict(page=1, left=17.25, top=-400.75, width=411.5, height=617.25),
                 dict(page=2, left=-12.5, top=240.5, width=577.75, height=385.1667)]
        width, height = 640, 481
        paths = [directory / f'part-{i}.rgba' for i in range(3)]
        assert 'error' not in worker.request(action='refine', height=height, pages=pages,
                                            parts=[dict(width=width, offset=0, file=str(paths[0]))])
        assert 'error' not in worker.request(action='refine', height=height, pages=pages,
                                            parts=[dict(width=239, offset=0, file=str(paths[1])),
                                                   dict(width=401, offset=239, file=str(paths[2]))])
        whole = np.frombuffer(paths[0].read_bytes(), dtype=np.uint8).reshape(height, width, 4)
        joined = np.concatenate([np.frombuffer(p.read_bytes(), dtype=np.uint8).reshape(height, w, 4)
                                 for p, w in zip(paths[1:], [239, 401])], axis=1)
        delta = np.abs(whole.astype(np.int16) - joined.astype(np.int16))
        assert delta.max() <= 1 and delta.mean() < .001, (delta.max(), delta.mean())
        assert np.all(whole[:, :, 3] == 255), 'Paper and page-gap output remain opaque'
        assert tuple(whole[230, 300]) == (32, 36, 44, 255), 'Page gap preserves the viewport background'

        # Idle output can exceed the motion budget, but never its own 64 MiB cap.
        large = directory / 'high-density.rgba'
        worker.checked(action='refine', height=2049, pages=[valid_page],
                       parts=[dict(width=4096, offset=0, file=str(large))])
        assert large.stat().st_size == 4096 * 2049 * 4
        rejected = worker.request(action='refine', height=4097, pages=[valid_page],
                                  parts=[dict(width=4096, offset=0, file=str(unused))])
        assert 'error' in rejected and not unused.exists()
    finally:
        worker.close()

    # A vector edge at a large zoom must not inherit the 4096-source blur.
    edge_pdf = directory / 'vector edge.pdf'
    fixture(edge_pdf, b'0 0 0 rg 200 0 200 600 re f\n')
    worker = Worker(edge_pdf)
    try:
        page = dict(page=1, width=24000, height=36000, left=-12000+50.25, top=-17000,
                    px=2731, py=4096)
        width, height = 101, 10
        fine, coarse = directory / 'edge-fine.rgba', directory / 'edge-coarse.rgba'
        reply = worker.request(action='refine', height=height, pages=[page],
                               parts=[dict(width=width, offset=0, file=str(fine))])
        assert 'error' not in reply, reply
        pixels = np.frombuffer(fine.read_bytes(), dtype=np.uint8).reshape(height, width, 4)
        row = pixels[5, :, 0]
        fine_gray = int(np.sum((row > 0) & (row < 255)))
        assert np.all(row[:49] == 255) and np.all(row[52:] == 0) and fine_gray <= 2
        info = worker.request(action='info')
        if info.get('surface'):
            reply = worker.request(action='compose', height=height, pages=[page],
                                   parts=[dict(width=width, offset=0, file=str(coarse))])
            assert 'error' not in reply, reply
            row = np.frombuffer(coarse.read_bytes(), dtype=np.uint8).reshape(height, width, 4)[5, :, 0]
            coarse_gray = int(np.sum((row > 0) & (row < 255)))
            assert coarse_gray >= 6 and fine_gray < coarse_gray, (fine_gray, coarse_gray)
            print(f'Large vector edge: {coarse_gray} intermediate columns from cached scaling, {fine_gray} from refinement')
        assert fine.stat().st_size == width * height * 4, 'A large page allocates only visible output pixels'
    finally:
        worker.close()
print('PASS: viewport refinement, rotated CropBox, direct crop agreement, fractional stripes, gaps, opaque pixels, bounded outputs, invalid requests, and large-scale vector detail')
