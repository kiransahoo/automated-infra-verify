#!/bin/bash

# Function to generate a comprehensive HTML report with embedded D3.js visualization data
generate_report() {
    log "Generating  report..."
    
    # Create output directory if it doesn't exist
    mkdir -p "$(dirname "$REPORT_FILE")"
    
    # Calculate summary counts
    if [ -f "$SUMMARY_FILE" ]; then
        TOTAL_TESTS=$(grep -v "^$" "$SUMMARY_FILE" | wc -l)
        PASSED_TESTS=$(grep -c " - SUCCESS" "$SUMMARY_FILE")
        FAILED_TESTS=$(grep -c " - FAILED" "$SUMMARY_FILE")
        PARTIAL_TESTS=$(grep -c " - PARTIAL" "$SUMMARY_FILE")
        WARNING_TESTS=$(grep -c " - WARNING" "$SUMMARY_FILE")
        NOT_AVAILABLE_TESTS=$(grep -c " - NOT AVAILABLE" "$SUMMARY_FILE")
        
        # Add partial and not available tests to skipped count
        SKIPPED_TESTS=$((PARTIAL_TESTS + WARNING_TESTS + NOT_AVAILABLE_TESTS))
    else
        TOTAL_TESTS=0
        PASSED_TESTS=0
        FAILED_TESTS=0
        SKIPPED_TESTS=0
    fi
    
    # Extract successful connections to a temporary file
    SUCCESSFUL_CONNECTIONS="${OUTPUT_DIR}/successful_connections.txt"
    if [ -f "$SUMMARY_FILE" ]; then
        grep " - SUCCESS" "$SUMMARY_FILE" | grep -v "NOT AVAILABLE" > "$SUCCESSFUL_CONNECTIONS" 2>/dev/null || echo "" > "$SUCCESSFUL_CONNECTIONS"
    else
        echo "" > "$SUCCESSFUL_CONNECTIONS"
    fi
    
    # Start building the HTML report
    cat > "$REPORT_FILE" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Azure Infrastructure Readiness Test Report</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://d3js.org/d3.v7.min.js"></script>
    <style>
        body { 
            font-family: 'Segoe UI', Arial, sans-serif; 
            line-height: 1.6; 
            color: #333; 
            margin: 20px; 
        }
        h1, h2 { 
            color: #0078D4; 
        }
        h2 { 
            margin-top: 30px; 
            border-bottom: 1px solid #ddd; 
            padding-bottom: 10px; 
        }
        .success { color: #107C10; }
        .error { color: #d13438; }
        .warning { color: #ff8c00; }
        .partial { color: #3971cc; }
        .summary-card {
            border: 1px solid #ddd;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .big-number {
            font-size: 24px;
            font-weight: bold;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-bottom: 20px;
        }
        th, td {
            padding: 8px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #f2f2f2;
        }
        tr:hover {
            background-color: #f5f5f5;
        }
        .note {
            background-color: #f8f8f8;
            border-left: 4px solid #0078D4;
            padding: 10px;
            margin-bottom: 20px;
        }
        .visualization-container {
            border: 1px solid #ddd;
            border-radius: 8px;
            padding: 20px;
            margin: 20px 0;
            overflow: hidden;
            background-color: #f8f8f8;
            position: relative;
        }
        .filter-panel {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            margin-bottom: 15px;
            padding: 10px;
            background: #eee;
            border-radius: 5px;
            align-items: center;
        }
        .filter-group {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .filter-label {
            font-weight: bold;
            white-space: nowrap;
        }
        .filter-input {
            padding: 6px 10px;
            border-radius: 4px;
            border: 1px solid #ccc;
            min-width: 200px;
        }
        .button {
            padding: 6px 12px;
            background-color: #0078D4;
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-weight: bold;
        }
        .button:hover {
            background-color: #0063b1;
        }
        .legend {
            display: flex;
            flex-wrap: wrap;
            gap: 12px;
            margin-top: 15px;
        }
        .legend-item {
            display: flex;
            align-items: center;
            gap: 5px;
        }
        .legend-color {
            width: 15px;
            height: 15px;
            border-radius: 3px;
        }
        .tooltip {
            position: absolute;
            background: white;
            border: 1px solid #ddd;
            border-radius: 5px;
            padding: 10px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.2);
            pointer-events: none;
            z-index: 1000;
            max-width: 300px;
        }
        #visualization-area {
            width: 100%;
            height: 600px;
            background: white;
            border-radius: 5px;
            border: 1px solid #ddd;
            overflow: hidden;
        }
        .loading {
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            font-size: 18px;
            color: #666;
        }
        .debug-info {
            background-color: #f8f8f8;
            border: 1px solid #ccc;
            padding: 10px;
            margin-top: 10px;
            font-family: monospace;
            display: none;
        }
    </style>
</head>
<body>
    <h1>Azure Infrastructure Readiness Test Report</h1>
    <p>Generated on: $(date)</p>
    
    <div class="summary-card">
        <h2>Summary</h2>
        <table>
            <tr>
                <th>Total Tests</th>
                <th>Passed</th>
                <th>Failed</th>
                <th>Skipped/Partial</th>
            </tr>
            <tr>
                <td class="big-number">$TOTAL_TESTS</td>
                <td class="big-number success">$PASSED_TESTS</td>
                <td class="big-number error">$FAILED_TESTS</td>
                <td class="big-number warning">$SKIPPED_TESTS</td>
            </tr>
        </table>
    </div>
    
    <h2>Network Connectivity Visualization</h2>
    <div class="visualization-container">
        <div class="filter-panel">
            <div class="filter-group">
                <span class="filter-label">Filter by Resource Type:</span>
                <select id="resource-filter" class="filter-input">
                    <option value="all">All Resources</option>
                    <option value="AKS">AKS Clusters</option>
                    <option value="VM">Virtual Machines</option>
                    <option value="SQL">SQL Servers</option>
                    <option value="Storage">Storage Accounts</option>
                    <option value="ServiceBus">Service Bus Namespaces</option>
                    <option value="EventHub">Event Hub Namespaces</option>
                    <option value="CosmosDB">Cosmos DB Accounts</option>
                    <option value="OnPrem">On-premises Networks</option>
                    <option value="Custom">Custom Endpoints</option>
                </select>
            </div>
            <div class="filter-group">
                <span class="filter-label">Search by Name:</span>
                <input type="text" id="name-filter" class="filter-input" placeholder="Enter resource name">
                <button id="search-button" class="button">Search</button>
            </div>
            <div class="filter-group">
                <button id="reset-filters" class="button">Reset Filters</button>
                <button id="reset-zoom" class="button">Reset Zoom</button>
            </div>
        </div>
        
        <div id="visualization-area">
            <div class="loading">Loading visualization...</div>
        </div>
        
        <div class="legend">
            <div class="legend-item"><div class="legend-color" style="background-color: #0078D4;"></div>AKS Clusters</div>
            <div class="legend-item"><div class="legend-color" style="background-color: #773AAB;"></div>Virtual Machines</div>
            <div class="legend-item"><div class="legend-color" style="background-color: #0072C6;"></div>SQL Servers</div>
            <div class="legend-item"><div class="legend-color" style="background-color: #FFB900;"></div>Storage Accounts</div>
            <div class="legend-item"><div class="legend-color" style="background-color: #00BCF2;"></div>Service Bus</div>
            <div class="legend-item"><div class="legend-color" style="background-color: #EB3C00;"></div>Event Hub</div>
            <div class="legend-item"><div class="legend-color" style="background-color: #3999C6;"></div>Cosmos DB</div>
            <div class="legend-item"><div class="legend-color" style="background-color: #107C10;"></div>On-premises</div>
            <div class="legend-item"><div class="legend-color" style="background-color: #E74C3C;"></div>Custom Endpoints</div>
        </div>
        
        <div id="debug-info" class="debug-info"></div>
    </div>
    
    <script>
    document.addEventListener('DOMContentLoaded', function() {
        // Debug function
        function debug(message) {
            console.log(message);
            const debugEl = document.getElementById('debug-info');
            if (debugEl) {
                debugEl.style.display = 'block';
                debugEl.innerHTML += message + '<br>';
            }
        }
        
        try {
            // DIRECTLY EMBEDDED GRAPH DATA
            const graphData = {
                nodes: [],
                links: []
            };
            
            // Process nodes and connections
            debug("Starting visualization...");
EOF

    # Process the connectivity data and embed directly in the JavaScript
    
    # First, create a unique list of nodes
    NODES_FILE="${OUTPUT_DIR}/unique_nodes.txt"
    awk -F' to | - ' '{print $1}' "$SUCCESSFUL_CONNECTIONS" > "${NODES_FILE}.src" 2>/dev/null || true
    awk -F' to | - ' '{print $2}' "$SUCCESSFUL_CONNECTIONS" > "${NODES_FILE}.dst" 2>/dev/null || true
    sort -u "${NODES_FILE}.src" "${NODES_FILE}.dst" > "$NODES_FILE" 2>/dev/null || touch "$NODES_FILE"
    
    # Add node information directly to the JavaScript
    NODE_COUNT=0
    NODE_MAP="${OUTPUT_DIR}/node_map.txt"
    > "$NODE_MAP"
    
    # Start the nodes array
    echo "            // Nodes" >> "$REPORT_FILE"
    
    FIRST_NODE=true
    while IFS= read -r node || [ -n "$node" ]; do
        # Skip empty lines
        [ -z "$node" ] && continue
        
        # Determine node type and color
        TYPE="Other"
        COLOR="#777777"
        
        if [[ "$node" == AKS:* ]]; then
            TYPE="AKS"
            COLOR="#0078D4"
        elif [[ "$node" == VM:* ]]; then
            TYPE="VM" 
            COLOR="#773AAB"
        elif [[ "$node" == SQL:* ]]; then
            TYPE="SQL"
            COLOR="#0072C6"
        elif [[ "$node" == Storage:* ]]; then
            TYPE="Storage"
            COLOR="#FFB900"
        elif [[ "$node" == ServiceBus:* ]]; then
            TYPE="ServiceBus"
            COLOR="#00BCF2"
        elif [[ "$node" == EventHub:* ]]; then
            TYPE="EventHub"
            COLOR="#EB3C00"
        elif [[ "$node" == CosmosDB:* ]]; then
            TYPE="CosmosDB"
            COLOR="#3999C6"
        elif [[ "$node" == OnPrem:* ]]; then
            TYPE="OnPrem"
            COLOR="#107C10"
        
        elif [[ "$node" == Custom:* ]]; then
            TYPE="Custom"
            COLOR="#E74C3C"
        fi
        # Handle commas between nodes
        if [ "$FIRST_NODE" = true ]; then
            FIRST_NODE=false
        else
            echo "," >> "$REPORT_FILE"
        fi
        
        # Escape special characters for JavaScript
        NODE_ESCAPED=$(echo "$node" | sed 's/\\/\\\\/g; s/"/\\"/g; s/'"'"'/\\'"'"'/g')
        
        # Add node entry directly to JavaScript
        cat >> "$REPORT_FILE" << EOF
            graphData.nodes.push({
                id: $NODE_COUNT,
                name: "$NODE_ESCAPED",
                type: "$TYPE",
                color: "$COLOR"
            })
EOF
        
        # Save node mapping for links
        echo "$node|$NODE_COUNT" >> "$NODE_MAP"
        
        NODE_COUNT=$((NODE_COUNT + 1))
    done < "$NODES_FILE"
    
    # Add links directly to JavaScript
    echo "            // Links" >> "$REPORT_FILE"
    
    FIRST_LINK=true
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines
        [ -z "$line" ] && continue
        
        if [[ "$line" == *" to "*" - SUCCESS"* ]]; then
            # Extract source, destination and connection time
            SRC=$(echo "$line" | awk -F' to ' '{print $1}')
            DST=$(echo "$line" | awk -F' to | - ' '{print $2}')
            
            # Get source and destination IDs
            SRC_ID=$(grep "^$SRC|" "$NODE_MAP" | cut -d'|' -f2)
            DST_ID=$(grep "^$DST|" "$NODE_MAP" | cut -d'|' -f2)
            
            # Skip if source or destination not found
            [ -z "$SRC_ID" ] || [ -z "$DST_ID" ] && continue
            
            # Extract connection time
            CONN_TIME=""
            VALUE="1"
            
            if [[ "$line" == *"Connection: "* ]]; then
                CONN_TIME=$(echo "$line" | grep -o 'Connection: [0-9.]*s' | sed 's/Connection: //')
                # Value reflects connection speed (faster = thicker line)
                TIME_VALUE=$(echo "$CONN_TIME" | grep -o '[0-9.]*' || echo "1")
                if [ -n "$TIME_VALUE" ] && [ "$TIME_VALUE" != "0" ]; then
                    VALUE=$(echo "scale=2; 5 / $TIME_VALUE" | bc 2>/dev/null || echo "1")
                    # Ensure value is between 1 and 5
                    VALUE=$(echo "$VALUE < 1 ? 1 : ($VALUE > 5 ? 5 : $VALUE)" | bc 2>/dev/null || echo "1")
                fi
            elif [[ "$line" == *"Connection Time: "* ]]; then
                CONN_TIME=$(echo "$line" | grep -o 'Connection Time: [0-9.]*s' | sed 's/Connection Time: //')
                # Value reflects connection speed (faster = thicker line)
                TIME_VALUE=$(echo "$CONN_TIME" | grep -o '[0-9.]*' || echo "1")
                if [ -n "$TIME_VALUE" ] && [ "$TIME_VALUE" != "0" ]; then
                    VALUE=$(echo "scale=2; 5 / $TIME_VALUE" | bc 2>/dev/null || echo "1")
                    # Ensure value is between 1 and 5
                    VALUE=$(echo "$VALUE < 1 ? 1 : ($VALUE > 5 ? 5 : $VALUE)" | bc 2>/dev/null || echo "1")
                fi
            elif [[ "$line" == *"reachable (Avg: "* ]]; then
                CONN_TIME=$(echo "$line" | grep -o 'Avg: [0-9]\+ms' | head -1)
                # Value reflects connection speed (faster = thicker line)
                TIME_VALUE=$(echo "$CONN_TIME" | grep -o '[0-9]\+' || echo "1")
                if [ -n "$TIME_VALUE" ] && [ "$TIME_VALUE" != "0" ]; then
                    VALUE=$(echo "scale=2; 5 / $TIME_VALUE" | bc 2>/dev/null || echo "1")
                    # Ensure value is between 1 and 5
                    VALUE=$(echo "$VALUE < 1 ? 1 : ($VALUE > 5 ? 5 : $VALUE)" | bc 2>/dev/null || echo "1")
                fi
            fi
            
            # Escape special characters for JavaScript
            SRC_ESCAPED=$(echo "$SRC" | sed 's/\\/\\\\/g; s/"/\\"/g; s/'"'"'/\\'"'"'/g')
            DST_ESCAPED=$(echo "$DST" | sed 's/\\/\\\\/g; s/"/\\"/g; s/'"'"'/\\'"'"'/g')
            CONN_TIME_ESCAPED=$(echo "$CONN_TIME" | sed 's/\\/\\\\/g; s/"/\\"/g; s/'"'"'/\\'"'"'/g')
            
            # Add link entry directly to JavaScript
            cat >> "$REPORT_FILE" << EOF
            graphData.links.push({
                source: $SRC_ID,
                target: $DST_ID,
                sourceName: "$SRC_ESCAPED",
                targetName: "$DST_ESCAPED",
                value: $VALUE,
                time: "$CONN_TIME_ESCAPED"
            })
EOF
        fi
    done < "$SUCCESSFUL_CONNECTIONS"
    
    # Continue with the rest of the JavaScript for visualization
    cat >> "$REPORT_FILE" << 'EOF'
            
            debug("Graph data loaded: " + graphData.nodes.length + " nodes, " + graphData.links.length + " links");
            
            // Check if we have any data
            if (graphData.nodes.length === 0) {
                document.querySelector('.loading').textContent = 'No connectivity data available for visualization.';
                return;
            }
            
            try {
                createVisualization(graphData);
                debug("Visualization created successfully");
            } catch (error) {
                console.error("Error creating visualization:", error);
                document.querySelector('.loading').textContent = 'Error creating visualization: ' + error.message;
                document.getElementById('debug-info').style.display = 'block';
                document.getElementById('debug-info').textContent += "Error details: " + error.stack;
            }
            
            function createVisualization(data) {
                // Store original data for filtering
                const originalData = JSON.parse(JSON.stringify(data));
                
                // Remove loading message
                document.querySelector('.loading').remove();
                
                // Setup SVG
                const container = document.getElementById('visualization-area');
                const width = container.clientWidth;
                const height = container.clientHeight;
                
                // Create SVG element
                const svg = d3.select('#visualization-area')
                    .append('svg')
                    .attr('width', '100%')
                    .attr('height', '100%')
                    .attr('viewBox', [0, 0, width, height]);
                    
                // Add zoom functionality
                const zoom = d3.zoom()
                    .scaleExtent([0.1, 10])
                    .on('zoom', (event) => {
                        g.attr('transform', event.transform);
                    });
                    
                svg.call(zoom);
                
                // Create group for zoom transform
                const g = svg.append('g');
                
                // Add arrow marker for links
                svg.append('defs').append('marker')
                    .attr('id', 'arrow')
                    .attr('viewBox', '0 -5 10 10')
                    .attr('refX', 25)
                    .attr('refY', 0)
                    .attr('markerWidth', 6)
                    .attr('markerHeight', 6)
                    .attr('orient', 'auto')
                    .append('path')
                    .attr('fill', '#666')
                    .attr('d', 'M0,-5L10,0L0,5');
                    
                // Create tooltip
                const tooltip = d3.select('body').append('div')
                    .attr('class', 'tooltip')
                    .style('opacity', 0);
                    
                // Create force simulation
                const simulation = d3.forceSimulation(data.nodes)
                    .force('link', d3.forceLink(data.links).id(d => d.id).distance(150))
                    .force('charge', d3.forceManyBody().strength(-400))
                    .force('center', d3.forceCenter(width / 2, height / 2))
                    .force('collision', d3.forceCollide().radius(60));
                    
                // Draw links
                const link = g.append('g')
                    .selectAll('line')
                    .data(data.links)
                    .join('line')
                    .attr('stroke', '#666')
                    .attr('stroke-opacity', 0.6)
                    .attr('stroke-width', d => Math.sqrt(d.value) * 2)
                    .attr('marker-end', 'url(#arrow)');
                    
                // Add connection time labels
                const linkLabels = g.append('g')
                    .selectAll('text')
                    .data(data.links)
                    .join('text')
                    .attr('font-size', '10px')
                    .attr('text-anchor', 'middle')
                    .attr('dy', -5)
                    .attr('pointer-events', 'none')
                    .text(d => d.time);
                    
                // Draw nodes
                const node = g.append('g')
                    .selectAll('circle')
                    .data(data.nodes)
                    .join('circle')
                    .attr('r', 30)
                    .attr('fill', d => d.color)
                    .attr('stroke', '#fff')
                    .attr('stroke-width', 2)
                    .call(drag(simulation));
                    
                // Add node labels
                const nodeLabels = g.append('g')
                    .selectAll('text')
                    .data(data.nodes)
                    .join('text')
                    .attr('text-anchor', 'middle')
                    .attr('dy', 4)
                    .attr('font-size', '12px')
                    .attr('fill', '#fff')
                    .attr('pointer-events', 'none')
                    .text(d => {
                        const parts = d.name.split(':');
                        if (parts.length > 1) {
                            // For Custom endpoints, show the actual hostname/IP
                            if (parts[0] === "Custom") {
                                return parts[1];
                            }
                            return parts[1];
                        }
                        return d.name;
                    });
                    
                // Add hover functionality
                node.on('mouseover', function(event, d) {
                        // Highlight node
                        d3.select(this)
                            .attr('stroke', '#333')
                            .attr('stroke-width', 3);
                            
                        // Show tooltip
                        tooltip.transition()
                            .duration(200)
                            .style('opacity', 0.9);
                        tooltip.html(`<strong>${d.name}</strong>`)
                            .style('left', (event.pageX + 10) + 'px')
                            .style('top', (event.pageY - 28) + 'px');
                            
                        // Highlight connected links and nodes
                        const connectedLinks = data.links.filter(l => l.source.id === d.id || l.target.id === d.id);
                        const connectedNodes = new Set();
                        
                        connectedLinks.forEach(l => {
                            connectedNodes.add(l.source.id === d.id ? l.target.id : l.source.id);
                            d3.select(link.nodes()[data.links.indexOf(l)])
                                .attr('stroke', '#ff7700')
                                .attr('stroke-width', l => Math.sqrt(l.value) * 3)
                                .attr('stroke-opacity', 1);
                        });
                        
                        node.filter(n => connectedNodes.has(n.id))
                            .attr('stroke', '#ff7700')
                            .attr('stroke-width', 3);
                    })
                    .on('mouseout', function() {
                        // Reset node
                        d3.select(this)
                            .attr('stroke', '#fff')
                            .attr('stroke-width', 2);
                            
                        // Hide tooltip
                        tooltip.transition()
                            .duration(500)
                            .style('opacity', 0);
                            
                        // Reset links and nodes
                        link.attr('stroke', '#666')
                            .attr('stroke-opacity', 0.6)
                            .attr('stroke-width', d => Math.sqrt(d.value) * 2);
                            
                        node.attr('stroke', '#fff')
                            .attr('stroke-width', 2);
                    });
                    
                // Update positions on simulation tick
                simulation.on('tick', () => {
                    link
                        .attr('x1', d => d.source.x)
                        .attr('y1', d => d.source.y)
                        .attr('x2', d => d.target.x)
                        .attr('y2', d => d.target.y);
                        
                    linkLabels
                        .attr('x', d => (d.source.x + d.target.x) / 2)
                        .attr('y', d => (d.source.y + d.target.y) / 2);
                        
                    node
                        .attr('cx', d => d.x = Math.max(30, Math.min(width - 30, d.x)))
                        .attr('cy', d => d.y = Math.max(30, Math.min(height - 30, d.y)));
                        
                    nodeLabels
                        .attr('x', d => d.x)
                        .attr('y', d => d.y);
                });
                
                // Set up drag behavior
                function drag(simulation) {
                    function dragstarted(event) {
                        if (!event.active) simulation.alphaTarget(0.3).restart();
                        event.subject.fx = event.subject.x;
                        event.subject.fy = event.subject.y;
                    }
                    
                    function dragged(event) {
                        event.subject.fx = event.x;
                        event.subject.fy = event.y;
                    }
                    
                    function dragended(event) {
                        if (!event.active) simulation.alphaTarget(0);
                        event.subject.fx = null;
                        event.subject.fy = null;
                    }
                    
                    return d3.drag()
                        .on('start', dragstarted)
                        .on('drag', dragged)
                        .on('end', dragended);
                }
                
                // Set up filter functionality
                function filterGraph() {
    const resourceType = document.getElementById('resource-filter').value;
    const nameFilter = document.getElementById('name-filter').value.toLowerCase();
    
    if (resourceType === 'all' && nameFilter === '') {
        // Reset to original data
        updateGraph(originalData);
        return;
    }
    
    // First, identify nodes that match the filters directly
    const matchingNodes = originalData.nodes.filter(node => {
        const matchesType = resourceType === 'all' || node.type === resourceType;
        const matchesName = nameFilter === '' || node.name.toLowerCase().includes(nameFilter);
        return matchesType && matchesName;
    });
    
    // Get IDs of matching nodes
    const matchingNodeIds = new Set(matchingNodes.map(n => n.id));
    
    // Find all connected nodes (for showing complete connections)
    const connectedNodeIds = new Set(matchingNodeIds);
    
    originalData.links.forEach(link => {
        const sourceId = typeof link.source === 'object' ? link.source.id : link.source;
        const targetId = typeof link.target === 'object' ? link.target.id : link.target;
        
        // If either end of the link is in our matching set, include both ends
        if (matchingNodeIds.has(sourceId)) {
            connectedNodeIds.add(targetId); // Add the target node
        }
        if (matchingNodeIds.has(targetId)) {
            connectedNodeIds.add(sourceId); // Add the source node
        }
    });
    
    // Get all nodes that are either matching or connected to matching nodes
    const filteredNodes = originalData.nodes.filter(node => 
        connectedNodeIds.has(node.id)
    );
    
    // Get all links between the nodes in our final set
    const filteredLinks = originalData.links.filter(link => {
        const sourceId = typeof link.source === 'object' ? link.source.id : link.source;
        const targetId = typeof link.target === 'object' ? link.target.id : link.target;
        
        // Keep links where at least one end is in our matching set
        // (this ensures we see all connections from the filtered resources)
        return matchingNodeIds.has(sourceId) || matchingNodeIds.has(targetId);
    });
    
    // Highlight primary nodes (those that match the filter directly)
    filteredNodes.forEach(node => {
        node.isPrimary = matchingNodeIds.has(node.id);
    });
    
    // Update visualization
    updateGraph({
        nodes: filteredNodes,
        links: filteredLinks
    });
}
                
                // Update the graph with new data
                function updateGraph(newData) {
                    // Stop current simulation
                    simulation.stop();
                    
                    // Remove existing elements
                    g.selectAll('*').remove();
                    
                    // Recreate visualization with new data
                    const link = g.append('g')
                        .selectAll('line')
                        .data(newData.links)
                        .join('line')
                        .attr('stroke', '#666')
                        .attr('stroke-opacity', 0.6)
                        .attr('stroke-width', d => Math.sqrt(d.value) * 2)
                        .attr('marker-end', 'url(#arrow)');
                        
                    const linkLabels = g.append('g')
                        .selectAll('text')
                        .data(newData.links)
                        .join('text')
                        .attr('font-size', '10px')
                        .attr('text-anchor', 'middle')
                        .attr('dy', -5)
                        .attr('pointer-events', 'none')
                        .text(d => d.time);
                        
                    const node = g.append('g')
                        .selectAll('circle')
                        .data(newData.nodes)
                        .join('circle')
                        .attr('r', 30)
                        .attr('fill', d => d.color)
                         .attr('stroke', d => d.isPrimary ? '#ff7700' : '#fff')  // Highlight primary nodes
                        .attr('stroke-width', d => d.isPrimary ? 4 : 2)  // Thicker border for primary nodes
                        .call(drag(simulation));
                        
                    const nodeLabels = g.append('g')
                        .selectAll('text')
                        .data(newData.nodes)
                        .join('text')
                        .attr('text-anchor', 'middle')
                        .attr('dy', 4)
                        .attr('font-size', '12px')
                        .attr('fill', '#fff')
                        .attr('pointer-events', 'none')
                        .text(d => {
                            // Extract name after colon
                            const parts = d.name.split(':');
                            return parts.length > 1 ? parts[1] : d.name;
                        });
                        
                    // Add hover functionality
                    node.on('mouseover', function(event, d) {
                            // Highlight node
                            d3.select(this)
                                .attr('stroke', '#333')
                                .attr('stroke-width', 3);
                                
                            // Show tooltip
                            tooltip.transition()
                                .duration(200)
                                .style('opacity', 0.9);
                            tooltip.html(`<strong>${d.name}</strong>`)
                                .style('left', (event.pageX + 10) + 'px')
                                .style('top', (event.pageY - 28) + 'px');
                                
                            // Highlight connected links and nodes
                            const connectedLinks = newData.links.filter(l => {
                                const srcId = typeof l.source === 'object' ? l.source.id : l.source;
                                const tgtId = typeof l.target === 'object' ? l.target.id : l.target;
                                return srcId === d.id || tgtId === d.id;
                            });
                            
                            const connectedNodes = new Set();
                            
                            connectedLinks.forEach(l => {
                                const srcId = typeof l.source === 'object' ? l.source.id : l.source;
                                const tgtId = typeof l.target === 'object' ? l.target.id : l.target;
                                connectedNodes.add(srcId === d.id ? tgtId : srcId);
                                
                                const linkIndex = newData.links.indexOf(l);
                                if (linkIndex >= 0 && linkIndex < link.nodes().length) {
                                    d3.select(link.nodes()[linkIndex])
                                        .attr('stroke', '#ff7700')
                                        .attr('stroke-width', Math.sqrt(l.value) * 3)
                                        .attr('stroke-opacity', 1);
                                }
                            });
                            
                            node.filter(n => connectedNodes.has(n.id))
                                .attr('stroke', '#ff7700')
                                .attr('stroke-width', 3);
                        })
                        .on('mouseout', function() {
                            // Reset node
                            d3.select(this)
                                .attr('stroke', '#fff')
                                .attr('stroke-width', 2);
                                
                            // Hide tooltip
                            tooltip.transition()
                                .duration(500)
                                .style('opacity', 0);
                                
                            // Reset links and nodes
                            link.attr('stroke', '#666')
                                .attr('stroke-opacity', 0.6)
                                .attr('stroke-width', d => Math.sqrt(d.value) * 2);
                                
                            node.attr('stroke', '#fff')
                                .attr('stroke-width', 2);
                        });
                    
                    // Restart simulation with new data
                    simulation.nodes(newData.nodes)
                        .force('link', d3.forceLink(newData.links).id(d => d.id).distance(150))
                        .force('center', d3.forceCenter(width / 2, height / 2))
                        .alpha(1)
                        .restart();
                        
                    // Update positions on simulation tick
                    simulation.on('tick', () => {
                        link
                            .attr('x1', d => d.source.x)
                            .attr('y1', d => d.source.y)
                            .attr('x2', d => d.target.x)
                            .attr('y2', d => d.target.y);
                            
                        linkLabels
                            .attr('x', d => (d.source.x + d.target.x) / 2)
                            .attr('y', d => (d.source.y + d.target.y) / 2);
                            
                        node
                            .attr('cx', d => d.x = Math.max(30, Math.min(width - 30, d.x)))
                            .attr('cy', d => d.y = Math.max(30, Math.min(height - 30, d.y)));
                            
                        nodeLabels
                            .attr('x', d => d.x)
                            .attr('y', d => d.y);
                    });
                }
                
                // Set up event handlers for filtering
                document.getElementById('search-button').addEventListener('click', filterGraph);
                document.getElementById('name-filter').addEventListener('keypress', function(event) {
                    if (event.key === 'Enter') {
                        filterGraph();
                    }
                });
                document.getElementById('resource-filter').addEventListener('change', filterGraph);
                document.getElementById('reset-filters').addEventListener('click', function() {
                    document.getElementById('resource-filter').value = 'all';
                    document.getElementById('name-filter').value = '';
                    updateGraph(originalData);
                });
                document.getElementById('reset-zoom').addEventListener('click', function() {
                    svg.transition().duration(750).call(
                        zoom.transform,
                        d3.zoomIdentity
                    );
                });
            }
        } catch (error) {
            console.error("Error setting up visualization:", error);
            document.querySelector('.loading').textContent = 'Error setting up visualization: ' + error.message;
            document.getElementById('debug-info').style.display = 'block';
            document.getElementById('debug-info').textContent = error.stack;
        }
    });
    </script>
EOF
    
    # Add discovered resources table
    cat >> "$REPORT_FILE" << EOF
    
    <h2>Discovered Resources</h2>
    <table>
        <tr>
            <th>Resource Type</th>
            <th>Count</th>
        </tr>
EOF
    
    # Add resource counts
    for resource_file in "${OUTPUT_DIR}/vms.txt" "${OUTPUT_DIR}/aks_clusters.txt" "${OUTPUT_DIR}/sql_servers.txt" \
                         "${OUTPUT_DIR}/storage_accounts.txt" "${OUTPUT_DIR}/servicebus.txt" "${OUTPUT_DIR}/eventhub.txt" \
                         "${OUTPUT_DIR}/cosmosdb.txt" "${OUTPUT_DIR}/onprem_networks.txt" "${OUTPUT_DIR}/gateways.txt" "${OUTPUT_DIR}/custom_endpoints.txt"; do
        resource_name=""
        case "$resource_file" in
            *vms.txt) resource_name="Virtual Machines" ;;
            *aks_clusters.txt) resource_name="AKS Clusters" ;;
            *sql_servers.txt) resource_name="SQL Servers" ;;
            *storage_accounts.txt) resource_name="Storage Accounts" ;;
            *servicebus.txt) resource_name="Service Bus Namespaces" ;;
            *eventhub.txt) resource_name="Event Hub Namespaces" ;;
            *cosmosdb.txt) resource_name="Cosmos DB Accounts" ;;
            *onprem_networks.txt) resource_name="On-premises Networks" ;;
            *gateways.txt) resource_name="VPN Gateways and ExpressRoute Circuits" ;;
            *custom_endpoints.txt) resource_name="Custom Endpoints" ;;
        esac
        
        if [ -n "$resource_name" ] && [ -f "$resource_file" ]; then
            count=$(grep -v "^$" "$resource_file" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            echo "        <tr><td>$resource_name</td><td>$count</td></tr>" >> "$REPORT_FILE"
        fi
    done
    
    # Add test results table and close HTML
    cat >> "$REPORT_FILE" << EOF
    </table>
    
    <h2>Connectivity Test Results</h2>
    <table>
        <tr>
            <th>Source</th>
            <th>Destination</th>
            <th>Status</th>
            <th>Details</th>
        </tr>
EOF
    
    # Add connectivity test results
    if [ -f "$SUMMARY_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines
            [ -z "$line" ] && continue
            
            # Process connectivity test results
            if [[ "$line" == *" to "*" - "* ]]; then
                # Extract source, destination, status, and details
                src_dest="${line%% - *}"
                if [[ "$src_dest" == *" to "* ]]; then
                    source="${src_dest%% to *}"
                    dest="${src_dest#* to }"
                    status_details="${line#*- }"
                    
                    # Determine status and CSS class
                    if [[ "$status_details" == "SUCCESS"* ]]; then
                        status="SUCCESS"
                        css_class="success"
                        details="${status_details#SUCCESS}"
                        # Clean up details
                        details="${details#* - }"
                    elif [[ "$status_details" == "FAILED"* ]]; then
                        status="FAILED"
                        css_class="error"
                        details="${status_details#FAILED}"
                        # Clean up details
                        details="${details#* - }"
                    elif [[ "$status_details" == "PARTIAL"* ]]; then
                        status="PARTIAL"
                        css_class="partial"
                        details="${status_details#PARTIAL}"
                        # Clean up details
                        details="${details#* - }"
                    elif [[ "$status_details" == "NOT AVAILABLE"* ]]; then
                        status="NOT AVAILABLE"
                        css_class="warning"
                        details="${status_details#NOT AVAILABLE}"
                        # Clean up details
                        details="${details#* - }"
                    else
                        status="WARNING"
                        css_class="warning"
                        details="$status_details"
                    fi
                    
                    # Escape HTML special characters
                    source=$(echo "$source" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g')
                    dest=$(echo "$dest" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g')
                    details=$(echo "$details" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g')
                    
                    # Add table row
                    echo "        <tr><td>$source</td><td>$dest</td><td class=\"$css_class\">$status</td><td>$details</td></tr>" >> "$REPORT_FILE"
                fi
            else
                # Handle lines that don't match expected format
                line_escaped=$(echo "$line" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g')
                echo "        <tr><td colspan=\"4\">$line_escaped</td></tr>" >> "$REPORT_FILE"
            fi
        done < "$SUMMARY_FILE"
    else
        echo "        <tr><td colspan=\"4\">No test results found. Check $SUMMARY_FILE file.</td></tr>" >> "$REPORT_FILE"
    fi
    
    # Close HTML document
    cat >> "$REPORT_FILE" << EOF
    </table>
    
    <div class="note">
        <p>Full logs and details can be found in: <code>$OUTPUT_DIR</code></p>
        <p>To view this report in a browser, open: <code>$REPORT_FILE</code></p>
    </div>
    
    <script>
    // Show debug info on double-click
    document.addEventListener('dblclick', function() {
        document.getElementById('debug-info').style.display = 
            document.getElementById('debug-info').style.display === 'block' ? 'none' : 'block';
    });
    </script>
</body>
</html>
EOF
    
    # Clean up temporary files
    rm -f "$SUCCESSFUL_CONNECTIONS" "$NODES_FILE" "${NODES_FILE}.src" "${NODES_FILE}.dst" "$NODE_MAP"
    
    log_success "Report generated: $REPORT_FILE"
    
    # Try to open the report in a browser
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$REPORT_FILE" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$REPORT_FILE" >/dev/null 2>&1 &
    else
        log "Please open the report manually: $REPORT_FILE"
    fi
}