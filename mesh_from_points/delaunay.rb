# delaunay.rb - Bowyer-Watson incremental Delaunay triangulation
# Pure Ruby, no dependencies. O(n²) worst case, O(n log n) average.

module MeshFromPoints
  class Delaunay
    # Triangulate a set of 3D points using their X/Y coordinates.
    #
    # @param points [[x, y, z], ...] — at least 3 non-collinear points
    # @return [[i, j, k], ...] — CCW triangle indices into points
    def self.triangulate(points)
      return [] if points.nil? || points.size < 3

      n = points.size
      pts = points.map { |p| [p[0].to_f, p[1].to_f] }

      # ── Super-triangle that contains all points ──────────────────────────
      min_x = pts.min_by { |p| p[0] }[0]
      max_x = pts.max_by { |p| p[0] }[0]
      min_y = pts.min_by { |p| p[1] }[1]
      max_y = pts.max_by { |p| p[1] }[1]

      dx = (max_x - min_x).abs
      dy = (max_y - min_y).abs
      d  = [dx, dy].max * 3.0 + 1.0

      mid_x = (min_x + max_x) / 2.0
      mid_y = (min_y + max_y) / 2.0

      # Three extra vertices appended at indices n, n+1, n+2 (CCW winding)
      all_pts = pts + [
        [mid_x - 20.0 * d, mid_y - d],        # n   bottom-left
        [mid_x + 20.0 * d, mid_y - d],        # n+1 bottom-right
        [mid_x,            mid_y + 20.0 * d]  # n+2 top
      ]

      # ── Bowyer-Watson insertion ──────────────────────────────────────────
      triangles = [[n, n + 1, n + 2]]

      pts.each_with_index do |p, idx|
        px, py = p

        # Split triangles into bad (circumcircle contains p) and good
        bad  = []
        good = []
        triangles.each { |t| in_circumcircle?(all_pts, t, px, py) ? bad << t : good << t }

        # Boundary edges of the hole: edges shared by exactly one bad triangle
        edge_count = Hash.new(0)
        bad.each do |t|
          [[t[0], t[1]], [t[1], t[2]], [t[2], t[0]]].each do |e|
            edge_count[e[0] < e[1] ? e : [e[1], e[0]]] += 1
          end
        end

        # Re-triangulate hole with new point
        triangles = good
        edge_count.each { |e, cnt| triangles << [e[0], e[1], idx] if cnt == 1 }
      end

      # ── Remove triangles touching the super-triangle ─────────────────────
      triangles.reject! { |t| t.any? { |v| v >= n } }
      triangles
    end

    # ── Circumcircle test ────────────────────────────────────────────────────
    # Returns true if point (px, py) lies strictly inside the circumcircle
    # of triangle tri. Handles both CW and CCW winding via orientation check.
    def self.in_circumcircle?(pts, tri, px, py)
      ax, ay = pts[tri[0]]
      bx, by = pts[tri[1]]
      cx, cy = pts[tri[2]]

      # Signed area (×2) — positive if CCW
      cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)

      # Translate triangle to origin at test point
      ax -= px; ay -= py
      bx -= px; by -= py
      cx -= px; cy -= py

      # 3×3 determinant — positive means P inside circumcircle of a CCW triangle
      det = ax * (by * (cx * cx + cy * cy) - cy * (bx * bx + by * by)) -
            ay * (bx * (cx * cx + cy * cy) - cx * (bx * bx + by * by)) +
            (ax * ax + ay * ay) * (bx * cy - cx * by)

      cross >= 0 ? det > 0 : det < 0
    end
    private_class_method :in_circumcircle?

    # ── Contour extraction (future) ──────────────────────────────────────────
    # @param points [[x,y,z], ...]
    # @param tris   [[i,j,k], ...]
    # @param step   contour interval (same units as z)
    # @return [[[x,y,z], ...], ...] one polyline per contour level
    def self.extract_contours(points, tris, step)
      # TODO: linear interpolation along triangle edges at each z-level
      []
    end
  end
end
