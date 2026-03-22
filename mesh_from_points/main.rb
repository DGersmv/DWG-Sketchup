# main.rb - DWG-mesh for SketchUp (full analog of Graphisoft DWG-mesh)
# Dialog + callbacks for Topo Mesh from DXF/DWG

require 'sketchup'
require 'json'
require_relative 'delaunay'

module MeshFromPoints
  # Singleton dialog instance
  @dialog = nil

  def self.dialog
    return @dialog if @dialog && @dialog.visible?

    html_path = File.join(File.dirname(__FILE__), 'dialog.html')
    unless File.exist?(html_path)
      UI.messagebox("Файл диалога не найден: #{html_path}")
      return nil
    end

    @dialog = UI::HtmlDialog.new(
      dialog_title: 'Топо Mesh из DWG',
      preferences_key: 'DWG_MESH_TOPOMESH',
      width: 460,
      height: 600,
      left: 100,
      top: 100,
      resizable: true,
      style: UI::HtmlDialog::STYLE_UTILITY
    )

    @dialog.set_file(html_path)
    setup_callbacks(@dialog)
    @dialog
  end

  def self.setup_callbacks(dlg)
    # get_layer_list -> [[name, index], ...]
    dlg.add_action_callback('get_layer_list') do |_context|
      model = Sketchup.active_model
      return [] unless model

      layers = []
      model.layers.each_with_index do |layer, idx|
        next if layer.name.nil? || layer.name.empty?
        layers << [layer.name, idx]
      end
      layers
    end

    # get_sample_elevation_text(layerIdx) -> string
    dlg.add_action_callback('get_sample_elevation_text') do |_context, layer_idx|
      model = Sketchup.active_model
      return '' unless model

      idx = layer_idx.to_i
      return '' if idx < 0 || idx >= model.layers.size

      layer = model.layers[idx]
      sample = ''
      model.entities.each do |ent|
        next unless ent.respond_to?(:layer) && ent.layer == layer
        next unless ent.respond_to?(:text)
        sample = ent.text.to_s
        break
      end
      sample
    end

    # get_layer_stats(jsonPayload) -> string
    dlg.add_action_callback('get_layer_stats') do |_context, json_str|
      model = Sketchup.active_model
      return '' unless model

      begin
        payload = JSON.parse(json_str.to_s)
        arc_idx = payload['arcLayerIdx'].to_i
        text_idx = payload['textLayerIdx'].to_i
        arc_layer = (arc_idx >= 0 && arc_idx < model.layers.size) ? model.layers[arc_idx] : nil
        text_layer = (text_idx >= 0 && text_idx < model.layers.size) ? model.layers[text_idx] : nil

        arc_count = 0
        text_count = 0
        model.entities.each do |ent|
          next unless ent.respond_to?(:layer)
          arc_count += 1 if arc_layer && ent.layer == arc_layer && arc_entity?(ent)
          text_count += 1 if text_layer && ent.layer == text_layer && ent.respond_to?(:text)
        end
        "Дуг/полилиний: #{arc_count}\nТекстов: #{text_count}"
      rescue
        ''
      end
    end

    # create_topo_mesh(jsonPayload) -> bool
    dlg.add_action_callback('create_topo_mesh') do |_context, json_str|
      model = Sketchup.active_model
      return false unless model

      begin
        create_topo_mesh_impl(model, json_str)
      rescue => e
        UI.messagebox("Ошибка создания Mesh: #{e.message}")
        false
      end
    end
  end

  def self.arc_entity?(ent)
    ent.is_a?(Sketchup::Edge) || (ent.respond_to?(:vertices) && ent.vertices.size >= 2)
  end

  def self.create_topo_mesh_impl(model, json_str)
    payload = JSON.parse(json_str.to_s)
    arc_idx = payload['arcLayerIdx'].to_i
    text_idx = payload['textLayerIdx'].to_i
    radius_mm = (payload['radius'] || 3000).to_f
    sep = payload['separator'] == ',' ? ',' : '.'
    mesh_layer_idx = (payload['meshLayer'] || 0).to_i
    mesh_name = payload['meshName'] || 'TopoMesh'

    return false if arc_idx < 0 || text_idx < 0
    arc_layer = model.layers[arc_idx]
    text_layer = model.layers[text_idx]

    # Collect points from arcs/edges and match with text elevations
    points = collect_topo_points(model, arc_layer, text_layer, radius_mm, sep)
    return false if points.empty?

    # Triangulate and create mesh
    tris = MeshFromPoints::Delaunay.triangulate(points)
    return false if tris.empty?

    model.start_operation('Create Topo Mesh', true)
    mesh_layer = (mesh_layer_idx >= 0 && mesh_layer_idx < model.layers.size) ? model.layers[mesh_layer_idx] : nil
    group = model.entities.add_group
    group.name = mesh_name
    group.layer = mesh_layer if mesh_layer

    pts = points.map { |p| Geom::Point3d.new(p[0], p[1], p[2]) }
    tris.each do |tri|
      i, j, k = tri[0], tri[1], tri[2]
      next if i.nil? || j.nil? || k.nil?
      begin
        face = group.entities.add_face(pts[i], pts[j], pts[k])
        face.reverse! if face && face.normal.z < 0
      rescue
        # skip degenerate triangles
      end
    end

    model.commit_operation
    true
  end

  def self.collect_topo_points(model, arc_layer, text_layer, radius_mm, sep)
    arc_points = []
    text_items = []

    model.entities.each do |ent|
      next unless ent.respond_to?(:layer)
      if ent.layer == arc_layer
        pt = point_from_entity(ent)
        arc_points << pt if pt
      elsif ent.layer == text_layer && ent.respond_to?(:text)
        pt = point_from_text_entity(ent)
        val = parse_elevation(ent.text.to_s, sep)
        text_items << [pt, val] if pt && val
      end
    end

    radius = radius_mm / 1000.0
    points = []
    arc_points.each do |ax, ay|
      best = nil
      best_d = Float::INFINITY
      text_items.each do |(tx, ty), z|
        d = Math.sqrt((ax - tx)**2 + (ay - ty)**2)
        if d <= radius && d < best_d
          best_d = d
          best = z
        end
      end
      z = best || 0.0
      points << [ax, ay, z]
    end

    text_items.each do |(tx, ty), z|
      next if arc_points.any? { |ax, ay| Math.sqrt((ax - tx)**2 + (ay - ty)**2) <= radius }
      points << [tx, ty, z]
    end
    points
  end

  def self.point_from_entity(ent)
    if ent.is_a?(Sketchup::Edge) && ent.curve && ent.curve.respond_to?(:center)
      cp = ent.curve.center
      return [cp.x, cp.y]
    end
    if ent.respond_to?(:start) && ent.start
      pt = ent.start.position
      return [pt.x, pt.y]
    end
    if ent.respond_to?(:vertices) && !ent.vertices.empty?
      pt = ent.vertices.first.position
      return [pt.x, pt.y]
    end
    nil
  end

  def self.point_from_text_entity(ent)
    return nil unless ent.respond_to?(:point)
    pt = ent.point
    [pt.x, pt.y]
  end

  def self.parse_elevation(text, sep)
    text = text.to_s.strip
    return nil if text.empty?
    neg = false
    text = text[1..] if text[0] == '+'
    if text[0] == '-'
      neg = true
      text = text[1..]
    end
    return nil if text.empty?
    text = text.tr(',', '.') if sep == ','
    return nil unless text.match?(/^[\d.]+$/)
    val = text.to_f
    neg ? -val : val
  end

  def self.show_dialog
    dlg = dialog
    dlg.show if dlg
  end

  unless file_loaded?(__FILE__)
    menu = UI.menu('Plugins')
    menu.add_item('Топо Mesh из DWG') { show_dialog }
    file_loaded(__FILE__)
  end
end
