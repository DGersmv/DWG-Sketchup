# main.rb - Topo Mesh for SketchUp
# Builds mesh from imported component (DWG/DXF via SketchUp File > Import)

require 'sketchup'
require 'json'
require_relative 'delaunay'

module MeshFromPoints
  @dialog           = nil
  @edge_count_cache = {}    # definition.name => Integer (memoised for component list)

  def self.dialog
    return @dialog if @dialog && @dialog.visible?

    html_path = File.join(File.dirname(__FILE__), 'dialog.html')
    unless File.exist?(html_path)
      UI.messagebox("Файл диалога не найден: #{html_path}")
      return nil
    end

    @dialog = UI::HtmlDialog.new(
      dialog_title:    'Topo Mesh',
      preferences_key: 'DWG_MESH_TOPOMESH',
      width:           480,
      height:          680,
      left:            100,
      top:             100,
      resizable:       true,
      style:           UI::HtmlDialog::STYLE_UTILITY
    )
    @dialog.set_file(html_path)
    setup_callbacks(@dialog)
    @dialog
  end

  def self.setup_callbacks(dlg)
    # Open URL in system browser
    dlg.add_action_callback('open_url') do |_ctx, url|
      UI.openURL(url.to_s) if url && !url.empty?
    end

    # Get model layer names for mesh layer dropdown
    dlg.add_action_callback('get_model_layers') do |_ctx|
      model = Sketchup.active_model
      layers = model ? model.layers.map { |l| l.name } : []
      layers.to_json
    end

    # Inspect selected component(s) or group(s) and return a human-readable report.
    # SketchUp HtmlDialog may not pass return value to JS Promise, so we use execute_script.
    dlg.add_action_callback('inspect_selection') do |_ctx|
      model = Sketchup.active_model
      result = if model.nil?
                 { error: 'Нет активной модели' }
               elsif selection_to_containers(model.selection).empty?
                 { error: 'Выделите компонент или группу в модели SketchUp' }
               else
                 begin
                   JSON.parse(inspect_selection_impl(selection_to_containers(model.selection)))
                 rescue => e
                   UI.messagebox("Ошибка анализа: #{e.message}") rescue nil
                   { error: "#{e.class}: #{e.message}" }
                 end
               end
      json_str = result.to_json
      script = "if(typeof window.onInspectComplete==='function')window.onInspectComplete(#{json_str});"
      dlg.execute_script(script)
      json_str
    end

    # Build mesh from selection (component or group with edges, points, sub-components)
    dlg.add_action_callback('create_mesh_from_model') do |_ctx, json_str|
      model = Sketchup.active_model
      next ({ error: 'Нет активной модели' }).to_json unless model

      comps = selection_to_containers(model.selection)
      next ({ error: 'Выделите компонент или группу в модели SketchUp' }).to_json if comps.empty?

      begin
        create_mesh_from_model_impl(model, json_str, comps)
      rescue => e
        UI.messagebox("Ошибка (model mesh): #{e.message}")
        ({ error: e.message }).to_json
      end
    end
  end

  # ---------------------------------------------------------------------------

  # Selection can contain Group or ComponentInstance — both have .definition and .entities
  def self.selection_to_containers(selection)
    selection.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
  end

  # Round value to nearest multiple of step.
  def self.round_to_step(val, step)
    return val if step.nil? || step <= 0
    (val.to_f / step).round * step
  end

  # Distance from point (px, py) to polyline in 2D (min over all segments).
  def self.point_to_polyline_distance_2d(px, py, polyline)
    return Float::INFINITY if polyline.nil? || polyline.size < 2
    best = Float::INFINITY
    (0...polyline.size - 1).each do |i|
      ax, ay = polyline[i][0].to_f, polyline[i][1].to_f
      bx, by = polyline[i + 1][0].to_f, polyline[i + 1][1].to_f
      abx, aby = bx - ax, by - ay
      apx, apy = px - ax, py - ay
      denom = abx * abx + aby * aby
      t = denom > 0 ? ((apx * abx + apy * aby) / denom) : 0
      t = [[t, 1].min, 0].max
      cx = ax + t * abx
      cy = ay + t * aby
      d = Math.sqrt((px - cx)**2 + (py - cy)**2)
      best = d if d < best
    end
    best
  end

  # Collect edges from comps by tag. Returns [[p1,p2], ...] in model (inches).
  def self.collect_edges_by_tag(comps, tag_name)
    segs = []
    comps.each do |ci|
      world_t = world_transformation_for(ci)
      each_entity_with_transform(ci.definition.entities, world_t) do |ent, wt|
        next unless (ent.layer.name rescue '0') == tag_name
        next unless ent.is_a?(Sketchup::Edge)
        ps = ent.start.position.transform(wt)
        pe = ent.end.position.transform(wt)
        segs << [[ps.x, ps.y, ps.z], [pe.x, pe.y, pe.z]]
      end
    end
    segs
  end

  # Collect elevation markers (ComponentInstance/Group center, ConstructionPoint) by tag.
  # Returns [{ x:, y:, z: }, ...] in model inches.
  def self.collect_elevation_markers_by_tag(comps, tag_name)
    markers = []
    comps.each do |ci|
      world_t = world_transformation_for(ci)
      each_entity_with_transform(ci.definition.entities, world_t) do |ent, wt|
        next unless (ent.layer.name rescue '0') == tag_name
        case ent
        when Sketchup::ComponentInstance, Sketchup::Group
          bb = ent.bounds
          next if bb.empty?
          c = bb.center.transform(wt)
          markers << { x: c.x, y: c.y, z: c.z }
        when Sketchup::ConstructionPoint
          pt = ent.position.transform(wt)
          markers << { x: pt.x, y: pt.y, z: pt.z }
        end
      end
    end
    markers
  end

  MODEL_CHAIN_TOL = 0.001 # inches

  # Объединённый сбор точек: изолинии (с Z от маркеров) + отметки высоты.
  # Returns [[x,y,z], ...] in model inches.
  def self.collect_unified_points(comps, tag_isolines, tag_elevation, radius_inches, z_step_inches, pts_per_contour)
    points = []

    # 1) Точки из отметок высоты
    markers = collect_elevation_markers_by_tag(comps, tag_elevation)
    markers.each { |m| points << [m[:x], m[:y], m[:z]] }

    # 2) Точки вдоль изолиний (Z от ближайшей отметки)
    segs = collect_edges_by_tag(comps, tag_isolines)
    return points if segs.empty? || markers.empty?

    polylines = chain_edges_into_polylines(segs, MODEL_CHAIN_TOL)
    polylines.each do |pline|
      next if pline.size < 2
      best_z = nil
      best_d = Float::INFINITY
      markers.each do |m|
        d = point_to_polyline_distance_2d(m[:x], m[:y], pline)
        next if d > radius_inches
        if d < best_d
          best_d = d
          best_z = m[:z]
        end
      end
      next unless best_z
      z = round_to_step(best_z, z_step_inches)
      elevated = pline.map { |p| [p[0], p[1], z] }
      sampled = resample_polyline_n(elevated, pts_per_contour)
      points.concat(sampled)
    end

    points
  end

  def self.create_mesh_unified(model, comps, tag_isolines, tag_elevation, radius_inches, z_step_inches,
                               pts_per_contour, mesh_name, mesh_layer_name)
    raw_points = collect_unified_points(comps, tag_isolines, tag_elevation, radius_inches,
                                        z_step_inches, pts_per_contour)
    return ({ error: 'Нет точек. Проверьте теги изолиний и отметок.' }).to_json if raw_points.size < 3

    # Дедупликация по XY (без add_bbox_corners — mesh строго по данным)
    seen = {}
    points = []
    raw_points.each do |pt|
      key = [pt[0].round(4), pt[1].round(4)]
      unless seen.key?(key)
        seen[key] = true
        points << pt
      end
    end

    return ({ error: "Недостаточно уникальных точек (#{points.size})" }).to_json if points.size < 3

    tris = MeshFromPoints::Delaunay.triangulate(points)
    return ({ error: 'Триангуляция не дала результатов' }).to_json if tris.empty?

    model.start_operation('Create Topo Mesh', true)

    target_layer = nil
    unless mesh_layer_name.empty?
      target_layer = model.layers.find { |l| l.name == mesh_layer_name }
      target_layer ||= model.layers.add(mesh_layer_name)
    end

    group = model.entities.add_group
    group.name  = mesh_name
    group.layer = target_layer if target_layer

    pts = points.map { |x, y, z| Geom::Point3d.new(x, y, z) }
    tris.each do |tri|
      i, j, k = tri[0], tri[1], tri[2]
      next if i.nil? || j.nil? || k.nil?
      begin
        face = group.entities.add_face(pts[i], pts[j], pts[k])
        face.reverse! if face && face.normal.z < 0
      rescue
      end
    end

    model.commit_operation
    ({ ok: true, raw_count: raw_points.size, point_count: points.size, tri_count: tris.size }).to_json
  end

  def self.inspect_selection_impl(comps)
    m = 1.0 / 39.3701
    lines = []
    all_tags = {}

    comps.each_with_index do |ci, ci_idx|
      defn     = ci.definition
      entities = defn.entities

      # Count entity types (direct children only for the summary)
      d = { edges: 0, cpoints: 0, faces: 0, groups: 0, cis: 0 }
      entities.each do |e|
        case e
        when Sketchup::Edge              then d[:edges]   += 1
        when Sketchup::ConstructionPoint then d[:cpoints] += 1
        when Sketchup::Face              then d[:faces]   += 1
        when Sketchup::Group             then d[:groups]  += 1
        when Sketchup::ComponentInstance then d[:cis]     += 1
        end
      end

      bb = ci.bounds
      lines << "=== Компонент #{ci_idx + 1}: \"#{defn.name}\" ==="
      unless bb.empty?
        lines << "Bbox: X #{(bb.min.x*m).round(1)}…#{(bb.max.x*m).round(1)} | " \
                      "Y #{(bb.min.y*m).round(1)}…#{(bb.max.y*m).round(1)} | " \
                      "Z #{(bb.min.z*m).round(2)}…#{(bb.max.z*m).round(2)} м"
      end
      lines << "Прямо внутри: рёбра=#{d[:edges]}  точки=#{d[:cpoints]}  " \
                              "грани=#{d[:faces]}  группы=#{d[:groups]}  суб-CI=#{d[:cis]}"

      # Per-tag analysis: sub-ComponentInstances, Edges, ConstructionPoints (incl. nested)
      tag_data = Hash.new { |h, k| h[k] = { count: 0, z_min: 1e18, z_max: -1e18, sample: nil, kind: nil } }

      each_entity_with_transform(entities, world_transformation_for(ci)) do |e, world_t|
        tag = (e.layer.name rescue '0')
        case e
        when Sketchup::ComponentInstance, Sketchup::Group
          center = e.bounds.center.transform(world_t)
          z_c   = center.z * m rescue 0.0
          td    = tag_data[tag]
          td[:count] += 1
          td[:z_min]  = z_c if z_c < td[:z_min]
          td[:z_max]  = z_c if z_c > td[:z_max]
          td[:kind] ||= (e.is_a?(Sketchup::Group) ? :group : :sub_ci)
          if td[:sample].nil?
            sub_e = e.definition.entities.count { |x| x.is_a?(Sketchup::Edge) }
            sub_c = e.definition.entities.count { |x| x.is_a?(Sketchup::ComponentInstance) }
            sub_g = e.definition.entities.count { |x| x.is_a?(Sketchup::Group) }
            sub_f = e.definition.entities.count { |x| x.is_a?(Sketchup::Face) }
            td[:sample] = "edges=#{sub_e} groups=#{sub_g} sub-CI=#{sub_c} faces=#{sub_f}"
          end
        when Sketchup::Edge
          ps = e.start.position.transform(world_t)
          pe = e.end.position.transform(world_t)
          z_c = ((ps.z + pe.z) / 2.0) * m
          td = tag_data[tag]
          td[:count] += 1
          td[:z_min] = z_c if z_c < td[:z_min]
          td[:z_max] = z_c if z_c > td[:z_max]
          td[:kind] ||= :edges
          td[:sample] ||= "рёбра (отрезки изолиний)"
        when Sketchup::ConstructionPoint
          pt  = e.position.transform(world_t)
          z_c = pt.z * m
          td = tag_data[tag]
          td[:count] += 1
          td[:z_min] = z_c if z_c < td[:z_min]
          td[:z_max] = z_c if z_c > td[:z_max]
          td[:kind] ||= :points
          td[:sample] ||= "точки (ConstructionPoint)"
        else
          next
        end
        all_tags[tag] ||= { count: 0, z_min: 1e18, z_max: -1e18 }
        all_tags[tag][:count] += 1
        zt = all_tags[tag]
        zt[:z_min] = z_c if z_c < zt[:z_min]
        zt[:z_max] = z_c if z_c > zt[:z_max]
      end

      if tag_data.any?
        lines << ""
        lines << "ТЕГИ / СЛОИ (#{tag_data.size} уникальных):"
        tag_data.sort_by { |_, v| -v[:count] }.each do |tag, td|
          z_range = td[:z_min] == td[:z_max] ?
            "Z=#{td[:z_min].round(2)}" :
            "Z #{td[:z_min].round(2)}…#{td[:z_max].round(2)}"
          lines << "  \"#{tag}\"  ×#{td[:count]}  #{z_range} м"
          lines << "     (#{td[:sample]})" if td[:sample]
        end
      end
    end

    tag_names = all_tags.sort_by { |_, v| -v[:count] }.map { |n, _| n }

    { ok: true, report: lines.join("\n"), tags: tag_names }.to_json
  end

  # Full transformation from instance local space to model space.
  # For nested groups, walks up the hierarchy and multiplies transforms.
  def self.world_transformation_for(instance)
    return instance.transformation unless instance.respond_to?(:parent)
    owner = instance.parent.respond_to?(:parent) ? instance.parent.parent : nil
    return instance.transformation if owner.nil? || owner.is_a?(Sketchup::Model)
    return instance.transformation unless owner.is_a?(Sketchup::ComponentDefinition)
    instances = owner.instances
    return instance.transformation if instances.nil? || instances.empty?
    outer = instances[0]
    world_transformation_for(outer) * instance.transformation
  end

  # Recursively iterate entities with accumulated world transformation.
  # world_t: transform from local CS of current entities to model space.
  def self.each_entity_with_transform(entities, world_t = Geom::Transformation.new, depth = 0)
    return if depth > 8
    entities.each do |ent|
      next unless ent.valid? rescue true
      yield ent, world_t
      if ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
        defn = ent.definition rescue nil
        next unless defn && defn.valid?
        each_entity_with_transform(defn.entities, world_t * ent.transformation, depth + 1) { |e, t| yield e, t }
      end
    end
  end

  # Recurse into containers (Group/ComponentInstance) to collect entities.
  def self.each_entity_recursive(entities, depth = 0)
    return if depth > 8
    entities.each do |ent|
      next unless ent.valid? rescue true
      yield ent
      if ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
        defn = ent.definition rescue nil
        next unless defn && defn.valid?
        each_entity_recursive(defn.entities, depth + 1) { |e| yield e }
      end
    end
  end

  # Tolerance for vertex matching when chaining edges
  VERTEX_TOL = 1e-4

  def self.same_point?(a, b, tol = VERTEX_TOL)
    return false unless a && b && a.size >= 3 && b.size >= 3
    dx = a[0] - b[0]; dy = a[1] - b[1]; dz = a[2] - b[2]
    dx * dx + dy * dy + dz * dz < tol * tol
  end

  # Chain short edge segments into continuous polylines.
  # segments: array of [p1, p2] where p1, p2 are [x, y, z]
  # tol: optional tolerance (default VERTEX_TOL) — use MODEL_CHAIN_TOL for imported geometry
  # Returns: array of polylines, each is [[x,y,z], [x,y,z], ...]
  def self.chain_edges_into_polylines(segments, tol = VERTEX_TOL)
    return [] if segments.empty?
    used = {}
    polylines = []

    segments.each_with_index { |seg, i| used[i] = false }

    segments.each_with_index do |seg, idx|
      next if used[idx]
      p1, p2 = seg[0], seg[1]
      chain = [p1.dup, p2.dup]
      used[idx] = true

      # Grow forward from p2
      loop do
        found = nil
        segments.each_with_index do |s, i|
          next if used[i]
          a, b = s[0], s[1]
          if same_point?(b, chain.last, tol)
            chain << a.dup
            found = i
            break
          elsif same_point?(a, chain.last, tol)
            chain << b.dup
            found = i
            break
          end
        end
        break unless found
        used[found] = true
      end

      # Grow backward from p1
      loop do
        found = nil
        segments.each_with_index do |s, i|
          next if used[i]
          a, b = s[0], s[1]
          if same_point?(a, chain.first, tol)
            chain.unshift(b.dup)
            found = i
            break
          elsif same_point?(b, chain.first, tol)
            chain.unshift(a.dup)
            found = i
            break
          end
        end
        break unless found
        used[found] = true
      end

      polylines << chain
    end
    polylines
  end

  # Resample polyline to exactly n_pts points, uniformly by arc length.
  def self.resample_polyline_n(polyline, n_pts)
    return [] if polyline.size < 2 || n_pts < 2
    return polyline.dup if polyline.size == n_pts
    lens = [0.0]
    (1...polyline.size).each do |i|
      p0, p1 = polyline[i - 1], polyline[i]
      d = Math.sqrt((p1[0] - p0[0])**2 + (p1[1] - p0[1])**2 + (p1[2] - p0[2])**2)
      lens << lens.last + d
    end
    total = lens.last
    return polyline.dup if total <= 0
    (0...n_pts).map do |i|
      t = (i.to_f / (n_pts - 1)) * total
      idx = lens.bsearch_index { |l| l >= t } || lens.size - 1
      idx = [idx, polyline.size - 2].min
      p0, p1 = polyline[idx], polyline[idx + 1]
      seg_len = lens[idx + 1] - lens[idx]
      frac = seg_len > 0 ? (t - lens[idx]) / seg_len : 0
      [
        p0[0] + frac * (p1[0] - p0[0]),
        p0[1] + frac * (p1[1] - p0[1]),
        p0[2] + frac * (p1[2] - p0[2])
      ]
    end
  end

  # comps — array of Sketchup::ComponentInstance from current selection
  def self.create_mesh_from_model_impl(model, json_str, comps)
    payload         = JSON.parse(json_str.to_s)
    mesh_name       = (payload['meshName'] || 'TopoMesh').to_s
    mesh_layer_name = payload['meshLayer'].to_s
    tag_isolines    = (payload['tagIsolines'] || payload['modelTag'] || '').to_s
    tag_elevation   = (payload['tagElevation'] || '').to_s

    return ({ error: 'Выберите тег изолиний' }).to_json if tag_isolines.empty?
    return ({ error: 'Выберите тег отметок высоты' }).to_json if tag_elevation.empty?

    z_step_mm       = [(payload['zStep'] || 500).to_i, 100].max
    pts_per_contour = [(payload['ptsPerContour'] || 80).to_i, 10].max
    pts_per_contour = [pts_per_contour, 500].min
    radius_m        = [(payload['radius'] || 5.0).to_f, 0.1].max
    radius_inches   = radius_m * 39.3701
    z_step_inches   = (z_step_mm / 1000.0) * 39.3701

    create_mesh_unified(model, comps, tag_isolines, tag_elevation, radius_inches, z_step_inches,
                        pts_per_contour, mesh_name, mesh_layer_name)
  end

  def self.show_dialog
    # Always recreate dialog so callbacks are up to date
    if @dialog
      @dialog.close rescue nil
      @dialog = nil
    end
    dlg = dialog
    dlg.show if dlg
  end

  unless file_loaded?(__FILE__)
    menu = UI.menu('Plugins')
    menu.add_item('Topo Mesh') { show_dialog }
    file_loaded(__FILE__)
  end
end
