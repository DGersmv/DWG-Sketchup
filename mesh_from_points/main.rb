# main.rb - DXF Topo Mesh for SketchUp
# Reads DXF file directly, triangulates, creates mesh in the active model

require 'sketchup'
require 'json'
require_relative 'delaunay'
require_relative 'dxf_parser'

module MeshFromPoints
  @dialog  = nil
  @dxf_data = nil  # { layers:, geometry:, centroid: } from DxfParser.parse

  def self.dialog
    return @dialog if @dialog && @dialog.visible?

    html_path = File.join(File.dirname(__FILE__), 'dialog.html')
    unless File.exist?(html_path)
      UI.messagebox("Файл диалога не найден: #{html_path}")
      return nil
    end

    @dialog = UI::HtmlDialog.new(
      dialog_title:    'DXF Topo Mesh',
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
    # Open DXF file dialog, parse file, return JSON with layers
    dlg.add_action_callback('open_dxf_file') do |_ctx|
      path = UI.openpanel('Выберите DXF файл', '', 'DXF Files|*.dxf||')
      next ({ error: 'cancelled' }).to_json if path.nil? || path.empty?
      next ({ error: 'Файл не найден' }).to_json unless File.exist?(path)

      begin
        @dxf_data = MeshFromPoints::DxfParser.parse(path)
        {
          ok:       true,
          path:     path,
          layers:   @dxf_data[:layers],
          centroid: @dxf_data[:centroid]
        }.to_json
      rescue => e
        ({ error: e.message }).to_json
      end
    end

    # Return first text value found on the given layer (for format preview)
    dlg.add_action_callback('get_text_sample') do |_ctx, layer_name|
      next '' unless @dxf_data

      item = @dxf_data[:geometry].find do |g|
        g[:type] == :text && g[:layer].to_s == layer_name.to_s
      end
      item ? item[:value].to_s : ''
    end

    # Return stats JSON { arcs: N, texts: M } for selected layers
    dlg.add_action_callback('get_layer_stats') do |_ctx, json_str|
      next ({ arcs: 0, texts: 0 }).to_json unless @dxf_data

      begin
        payload    = JSON.parse(json_str.to_s)
        arc_layer  = payload['arcLayer'].to_s
        text_layer = payload['textLayer'].to_s

        arcs  = @dxf_data[:geometry].count { |g| geometry_is_arc?(g)  && g[:layer] == arc_layer }
        texts = @dxf_data[:geometry].count { |g| geometry_is_text?(g) && g[:layer] == text_layer }
        ({ arcs: arcs, texts: texts }).to_json
      rescue
        ({ arcs: 0, texts: 0 }).to_json
      end
    end

    # Open URL in system browser
    dlg.add_action_callback('open_url') do |_ctx, url|
      UI.openURL(url.to_s) if url && !url.empty?
    end

    # Create topo mesh in the active SketchUp model
    dlg.add_action_callback('create_topo_mesh') do |_ctx, json_str|
      model = Sketchup.active_model
      unless model && @dxf_data
        next false
      end

      begin
        create_topo_mesh_impl(model, json_str)
      rescue => e
        UI.messagebox("Ошибка создания Mesh: #{e.message}")
        false
      end
    end
  end

  # ---------------------------------------------------------------------------

  def self.geometry_is_arc?(g)
    [:arc, :circle, :polyline, :point].include?(g[:type])
  end

  def self.geometry_is_text?(g)
    g[:type] == :text
  end

  def self.create_topo_mesh_impl(model, json_str)
    payload    = JSON.parse(json_str.to_s)
    arc_layer  = payload['arcLayer'].to_s
    text_layer = payload['textLayer'].to_s
    radius     = (payload['radius'] || 5.0).to_f
    sep        = payload['separator'] == ',' ? ',' : '.'
    units      = payload['units'] || 'м'
    mesh_name  = (payload['meshName'] || 'TopoMesh').to_s
    mesh_layer_name = payload['meshLayer'].to_s

    return false if arc_layer.empty? || text_layer.empty?

    # Scale factor: DXF coordinate units → SketchUp inches
    scale = case units
            when 'мм' then 0.0393701
            when 'см' then 0.393701
            else 39.3701  # meters (default)
            end

    # Convert radius to inches (same unit as coordinates)
    radius_inches = radius * scale

    points = collect_topo_points(@dxf_data, arc_layer, text_layer, radius_inches, sep, scale)
    return false if points.size < 3

    tris = MeshFromPoints::Delaunay.triangulate(points)
    return false if tris.empty?

    model.start_operation('Create DXF Topo Mesh', true)

    # Find or create mesh layer
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
        # skip degenerate triangles
      end
    end

    model.commit_operation
    true
  end

  def self.collect_topo_points(dxf_data, arc_layer, text_layer, radius_inches, sep, scale)
    arc_pts = dxf_data[:geometry]
              .select { |g| geometry_is_arc?(g) && g[:layer] == arc_layer }
              .map    { |g| [g[:x] * scale, g[:y] * scale] }

    text_items = dxf_data[:geometry]
                 .select { |g| geometry_is_text?(g) && g[:layer] == text_layer }
                 .map    { |g| { x: g[:x] * scale, y: g[:y] * scale, z: parse_elevation(g[:value].to_s, sep) } }
                 .reject { |t| t[:z].nil? }

    points = []

    arc_pts.each do |ax, ay|
      best_z = nil
      best_d = Float::INFINITY
      text_items.each do |t|
        d = Math.sqrt((ax - t[:x])**2 + (ay - t[:y])**2)
        if d <= radius_inches && d < best_d
          best_d = d
          best_z = t[:z]
        end
      end
      points << [ax, ay, (best_z || 0.0)]
    end

    # Text points not covered by any arc → add as standalone points
    text_items.each do |t|
      covered = arc_pts.any? { |ax, ay| Math.sqrt((ax - t[:x])**2 + (ay - t[:y])**2) <= radius_inches }
      next if covered
      points << [t[:x], t[:y], t[:z]]
    end

    points
  end

  def self.parse_elevation(text, sep)
    text = text.to_s.strip.delete(' ')
    return nil if text.empty?

    neg = false
    text = text[1..] if text.start_with?('+')
    if text.start_with?('-')
      neg  = true
      text = text[1..]
    end

    text = text.tr(',', '.') if sep == ','
    return nil unless text.match?(/\A\d*\.?\d+\z/)

    val = text.to_f
    neg ? -val : val
  end

  def self.show_dialog
    dlg = dialog
    dlg.show if dlg
  end

  unless file_loaded?(__FILE__)
    menu = UI.menu('Plugins')
    menu.add_item('DXF Topo Mesh') { show_dialog }
    file_loaded(__FILE__)
  end
end
