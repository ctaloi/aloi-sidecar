.pragma library

// Where each topic sits on the map. Topics that come up together pull
// toward each other, every topic pushes the rest away, and none may cover
// another's name. The same topics always land in the same places: it
// starts from a fixed spiral (the most-discussed in the middle), not from
// chance.
//
// boxes: [{name, r, lw, lh}] (the dot's radius; its name's width and height
// underneath). links: [{a, b, n}]. Returns {name: {x, y}}, the dot's centre.
function layout(boxes, links, w, h) {
    const n = boxes.length
    const out = {}
    if (n === 0 || w <= 0 || h <= 0) return out
    const pad = 8, aspect = w / h
    const at = {}
    const P = boxes.map((b, i) => {
        at[b.name] = i
        const turn = i * 2.399963, far = Math.sqrt((i + 0.5) / n)
        return {
            x: w / 2 + Math.cos(turn) * far * w * 0.40,
            y: h / 2 + Math.sin(turn) * far * h * 0.36,
            hw: Math.max(b.r, b.lw / 2) + 6,   // half the width it needs
            up: b.r + 4,                        // above the centre
            down: b.r + 6 + b.lh + 4            // below it, name and all
        }
    })
    let most = 1
    for (const l of links) most = Math.max(most, l.n)
    const springs = links.filter(l => l.a in at && l.b in at)
                         .map(l => ({ i: at[l.a], j: at[l.b], pull: 0.35 + 0.65 * l.n / most }))
    const tied = P.map(() => false)
    for (const s of springs) { tied[s.i] = true; tied[s.j] = true }

    function clamp(p) {
        p.x = Math.min(w - p.hw - pad, Math.max(p.hw + pad, p.x))
        p.y = Math.min(h - p.down - pad, Math.max(p.up + pad, p.y))
    }
    // Two that overlap move apart the shorter way, half each.
    function unstack() {
        for (let i = 0; i < n; ++i) {
            for (let j = i + 1; j < n; ++j) {
                const a = P[i], b = P[j]
                const dx = b.x - a.x
                const dy = (b.y + (b.down - b.up) / 2) - (a.y + (a.down - a.up) / 2)
                const ox = a.hw + b.hw - Math.abs(dx)
                const oy = (a.up + a.down + b.up + b.down) / 2 - Math.abs(dy)
                if (ox <= 0 || oy <= 0) continue
                if (ox < oy) {
                    const s = (dx >= 0 ? 1 : -1) * ox / 2
                    a.x -= s; b.x += s
                } else {
                    const s = (dy >= 0 ? 1 : -1) * oy / 2
                    a.y -= s; b.y += s
                }
            }
        }
        for (const p of P) clamp(p)
    }

    // Worked out as if the map were square (x squeezed by its aspect), so a
    // wide map spreads its topics wide instead of leaving its ends empty.
    const k = h / Math.sqrt(n + 1) * 0.85
    const rounds = 300
    for (let round = 0; round < rounds; ++round) {
        const heat = h / 6 * (1 - round / rounds) + 0.5
        const move = P.map(() => ({ x: 0, y: 0 }))
        for (let i = 0; i < n; ++i) {
            for (let j = i + 1; j < n; ++j) {
                let dx = (P[i].x - P[j].x) / aspect, dy = P[i].y - P[j].y
                if (dx === 0 && dy === 0) { dx = 0.5; dy = (i % 2 ? 0.5 : -0.5) }
                const d = Math.sqrt(dx * dx + dy * dy)
                const push = k * k / d / d
                move[i].x += dx * push; move[i].y += dy * push
                move[j].x -= dx * push; move[j].y -= dy * push
            }
        }
        for (const s of springs) {
            const dx = (P[s.i].x - P[s.j].x) / aspect, dy = P[s.i].y - P[s.j].y
            const d = Math.sqrt(dx * dx + dy * dy) || 1
            const pull = d / k * s.pull
            move[s.i].x -= dx * pull; move[s.i].y -= dy * pull
            move[s.j].x += dx * pull; move[s.j].y += dy * pull
        }
        for (let i = 0; i < n; ++i) {
            // Everything leans to the middle; a topic tied to nothing leans less, and drifts out.
            const lean = tied[i] ? 0.10 : 0.07
            move[i].x += (w / 2 - P[i].x) / aspect * lean
            move[i].y += (h / 2 - P[i].y) * lean
            const d = Math.sqrt(move[i].x * move[i].x + move[i].y * move[i].y) || 1
            const step = Math.min(d, heat) / d
            P[i].x += move[i].x * step * aspect
            P[i].y += move[i].y * step
            clamp(P[i])
        }
        if (round > rounds / 2) unstack()
    }
    for (let pass = 0; pass < 40; ++pass) unstack()
    boxes.forEach((b, i) => { out[b.name] = { x: Math.round(P[i].x), y: Math.round(P[i].y) } })
    return out
}
