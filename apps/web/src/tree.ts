// Tree helpers shared by the categories and locations screens. Rows are flat, linked by parent_id.
type Node = { id: string; parent_id: string | null; name: string }

// Flat rows to display order: each parent, then its children, by name. A row whose parent is
// not in the list (deleted, or not visible) shows at the top level.
export function buildTree<T extends Node>(rows: T[]): { row: T; depth: number }[] {
  const ids = new Set(rows.map((r) => r.id))
  // Children grouped by parent once, so a tree of thousands of locations stays linear.
  const children = new Map<string | null, T[]>()
  for (const row of [...rows].sort((a, b) => a.name.localeCompare(b.name))) {
    const p = row.parent_id && ids.has(row.parent_id) ? row.parent_id : null
    const list = children.get(p)
    if (list) list.push(row)
    else children.set(p, [row])
  }
  const out: { row: T; depth: number }[] = []
  const seen = new Set<string>()
  const walk = (parent: string | null, depth: number) => {
    for (const row of children.get(parent) ?? []) {
      if (seen.has(row.id)) continue
      seen.add(row.id)
      out.push({ row, depth })
      walk(row.id, depth + 1)
    }
  }
  walk(null, 0)
  return out
}

// The row and every ancestor, nearest first. Stops on a cycle the database already refuses.
export function lineage<T extends Node>(rows: T[], id: string): string[] {
  const byId = new Map(rows.map((r) => [r.id, r]))
  const out: string[] = []
  for (let c = byId.get(id); c && !out.includes(c.id); c = c.parent_id ? byId.get(c.parent_id) : undefined) out.push(c.id)
  return out
}
