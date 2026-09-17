"""Generate the approved Lift silhouette and verify its exact diagonal symmetry."""

from pathlib import Path

CANVAS = 256
MINIMUM = 62
STEP = 44
OUTER_RADIUS = 12
INNER_RADIUS = 6
MAXIMUM = MINIMUM + 3 * STEP

vertices = [
    (MINIMUM, MAXIMUM),
    (MINIMUM, MINIMUM + 2 * STEP),
    (MINIMUM + STEP, MINIMUM + 2 * STEP),
    (MINIMUM + STEP, MINIMUM + STEP),
    (MINIMUM + 2 * STEP, MINIMUM + STEP),
    (MINIMUM + 2 * STEP, MINIMUM),
    (MAXIMUM, MINIMUM),
    (MAXIMUM, MAXIMUM),
]


def direction(start, end):
    dx, dy = end[0] - start[0], end[1] - start[1]
    length = abs(dx) + abs(dy)
    assert (dx == 0) != (dy == 0), "Edges must be orthogonal."
    assert length > 2 * max(OUTER_RADIUS, INNER_RADIUS), "Adjacent corner arcs must not overlap."
    return (dx // length, dy // length), length


def mirror(point):
    return point[1], point[0]


corners = []
lengths = []
for index, vertex in enumerate(vertices):
    incoming, _ = direction(vertices[index - 1], vertex)
    outgoing, length = direction(vertex, vertices[(index + 1) % len(vertices)])
    sweep = int(incoming[0] * outgoing[1] - incoming[1] * outgoing[0] > 0)
    radius = OUTER_RADIUS if sweep else INNER_RADIUS
    entry = tuple(vertex[i] - incoming[i] * radius for i in (0, 1))
    exit_point = tuple(vertex[i] + outgoing[i] * radius for i in (0, 1))
    corners.append((entry, exit_point, radius, sweep))
    lengths.append(length)

assert MINIMUM + MAXIMUM == CANVAS, "Bounds must be centered on the canvas."
assert lengths == [STEP] * 6 + [3 * STEP] * 2, "All six stair runs must match."
assert set(vertices) == {mirror(vertex) for vertex in vertices}

# Compare every real line and circular arc with its reflected counterpart.
# Reflection reverses winding; reverse each segment to restore that winding.
segments = []
commands = [f"M{corners[-1][1][0]} {corners[-1][1][1]}"]
for index, (entry, exit_point, radius, sweep) in enumerate(corners):
    previous_exit = corners[index - 1][1]
    segments.extend([
        ("L", previous_exit, entry, 0, 0),
        ("A", entry, exit_point, radius, sweep),
    ])
    commands.extend([
        f"L{entry[0]} {entry[1]}",
        f"A{radius} {radius} 0 0 {sweep} {exit_point[0]} {exit_point[1]}",
    ])

reflected = {
    (kind, mirror(end), mirror(start), radius, sweep)
    for kind, start, end, radius, sweep in segments
}
assert set(segments) == reflected, "Rounded contour must be invariant under x/y reflection."

path = " ".join(commands + ["Z"])
svg = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 256 256">\n'
    f'  <path d="{path}" fill="#141414"/>\n'
    '</svg>\n'
)
root = Path(__file__).resolve().parent.parent
for destination in [
    root / "Sources/01-lift.svg",
    root / "Lift.icon/Assets/01-lift.svg",
    root.parents[2] / "Momenta/AppIcon.icon/Assets/01-lift.svg",
]:
    destination.write_text(svg)

print("Verified: y = x symmetry; 6 equal 44-unit stair runs; outer radius 12; inner radius 6.")
print(path)
