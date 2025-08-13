# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 NVIDIA Corporation. All rights reserved.
#
# DGX Cloud NVCF Material Extension - Polished UI Version
# Save this file and run: exec(open("path/to/this/file.py").read())

import omni.ext
import omni.ui as ui
import omni.usd
import asyncio
import aiohttp
import json
import time
from pxr import Usd, UsdShade, Sdf, Gf, UsdGeom

print("Loading DGX Cloud NVCF Material Extension with Polished UI...")
print("🔄 POLISHED UI VERSION - Working functionality with beautiful interface")

class DGXNVCFMaterialExtension(omni.ext.IExt):
    def on_startup(self, ext_id):
        print("DGX Cloud NVCF Material Extension Starting!")
        self._window = None
        self._create_ui()
        self._last_request_time = 0
        print("DGX Cloud NVCF Extension Ready!")
    
    def on_shutdown(self):
        print("DGX Cloud NVCF Extension shutting down...")
        if self._window:
            self._window.destroy()
            self._window = None
    
    def show_window(self):
        """Show/create the window"""
        if not self._window:
            self._create_ui()
        self._window.visible = True
        self._window.focus()
        print("DGX window shown")
    
    def hide_window(self):
        """Hide the window"""
        if self._window:
            self._window.visible = False
            print("DGX window hidden")
    
    def toggle_window(self):
        """Toggle window visibility"""
        if self._window and self._window.visible:
            self.hide_window()
        else:
            self.show_window()
    
    def _create_ui(self):
        """Create the AI material generation UI with modern styling"""
        if self._window:
            self._window.destroy()
            
        # Define color scheme
        COLORS = {
            'primary': 0xFF2E7D32,      # Dark green
            'secondary': 0xFF4CAF50,    # Light green  
            'accent': 0xFF81C784,       # Lighter green
            'background': 0xFF1E1E1E,   # Dark background
            'surface': 0xFF2D2D2D,      # Card background
            'text_primary': 0xFFFFFFFF, # White text
            'text_secondary': 0xFFBBBBBB, # Light gray text
            'warning': 0xFFFF9800,      # Orange
            'error': 0xFFF44336,        # Red
            'success': 0xFF4CAF50       # Green
        }
        
        self._window = ui.Window("DGX Cloud NVCF AI Materials + FLUX.1", width=520, height=900)
        
        with self._window.frame:
            with ui.VStack(spacing=0):
                
                # HEADER SECTION
                with ui.Frame(height=80, style={"background_color": COLORS['primary']}):
                    with ui.VStack(spacing=5):
                        ui.Spacer(height=15)
                        with ui.HStack():
                            ui.Spacer(width=20)
                            ui.Label("DGX Cloud NVCF + FLUX.1", 
                                    style={"font_size": 24, "color": COLORS['text_primary']})
                            ui.Spacer()
                        with ui.HStack():
                            ui.Spacer(width=20)
                            ui.Label("AI-Powered Material Generation", 
                                    style={"font_size": 14, "color": COLORS['accent']})
                            ui.Spacer()
                        ui.Spacer(height=10)
                
                # MAIN CONTENT AREA
                with ui.ScrollingFrame():
                    with ui.VStack(spacing=4):
                        ui.Spacer(height=3)
                        
                        # CONNECTION SETTINGS CARD
                        with ui.HStack():
                            ui.Spacer(width=20)
                            with ui.VStack(spacing=0):
                                # Card Header
                                with ui.Frame(height=40, style={"background_color": COLORS['secondary'], "border_radius": 8}):
                                    with ui.HStack():
                                        ui.Spacer(width=15)
                                        ui.Label("NVCF Connection", 
                                                style={"font_size": 16, "color": COLORS['text_primary']})
                                        ui.Spacer()
                                        self._connection_status = ui.Label("Not Connected", 
                                                                          style={"font_size": 12, "color": COLORS['text_primary']})
                                        ui.Spacer(width=15)
                                
                                # Card Content
                                with ui.Frame(style={"background_color": COLORS['surface'], "border_radius": 8}):
                                    with ui.VStack(spacing=8):
                                        ui.Spacer(height=8)
                                        
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            with ui.VStack(spacing=6):
                                                ui.Label("API Endpoint:", style={"color": COLORS['text_primary']})
                                                self._endpoint_input = ui.StringField(height=22)
                                                self._endpoint_input.model.set_value("https://api.nvcf.nvidia.com/v2/nvcf/pexec/functions/d068db74-322f-40a7-bc19-9113ff0efdc6")
                                            ui.Spacer(width=15)
                                        
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            with ui.VStack(spacing=6):
                                                ui.Label("API Key:", style={"color": COLORS['text_primary']})
                                                self._api_key_input = ui.StringField(height=22, password_mode=True)
                                                self._api_key_input.model.set_value("nvapi-xxx")
                                            ui.Spacer(width=15)
                                        
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            ui.Button("Test Connection", 
                                                     clicked_fn=self._test_connection,
                                                     height=30,
                                                     style={"background_color": COLORS['accent'], 
                                                           "color": COLORS['text_primary'],
                                                           "border_radius": 6})
                                            ui.Spacer()
                                            ui.Spacer(width=15)
                                        
                                        ui.Spacer(height=8)
                            ui.Spacer(width=20)
                        
                        # MATERIAL GENERATION CARD
                        with ui.HStack():
                            ui.Spacer(width=20)
                            with ui.VStack(spacing=0):
                                # Card Header
                                with ui.Frame(height=40, style={"background_color": COLORS['secondary'], "border_radius": 8}):
                                    with ui.HStack():
                                        ui.Spacer(width=15)
                                        ui.Label("Material Generation", 
                                                style={"font_size": 16, "color": COLORS['text_primary']})
                                        ui.Spacer()
                                
                                # Card Content
                                with ui.Frame(style={"background_color": COLORS['surface'], "border_radius": 8}):
                                    with ui.VStack(spacing=8):
                                        ui.Spacer(height=8)
                                        
                                        # Material Description
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            with ui.VStack(spacing=6):
                                                ui.Label("Material Description:", style={"color": COLORS['text_primary']})
                                                self._material_input = ui.StringField(height=22)
                                                self._material_input.model.set_value("bright red glossy paint")
                                            ui.Spacer(width=15)
                                        
                                        # Model Selection
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            with ui.VStack(spacing=6):
                                                ui.Label("Foundation Model:", style={"color": COLORS['text_primary']})
                                                with ui.HStack(spacing=10):
                                                    self._model_combo = ui.ComboBox(0, "FLUX.1-dev", "FLUX.1-schnell", "Custom Model", height=22)
                                                    ui.Button("Browse NGC", 
                                                             clicked_fn=self._browse_ngc,
                                                             height=22, width=100,
                                                             style={"background_color": COLORS['accent'],
                                                                   "color": COLORS['text_primary'],
                                                                   "border_radius": 4})
                                            ui.Spacer(width=15)
                                        
                                        # Quick Presets
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            with ui.VStack(spacing=6):
                                                ui.Label("Quick Presets:", style={"color": COLORS['text_primary']})
                                                
                                                # Row 1: Metals
                                                with ui.HStack(spacing=8):
                                                    ui.Button("Polished Chrome", 
                                                             clicked_fn=lambda: self._set_preset("polished chrome metal"),
                                                             height=26,
                                                             style={"background_color": 0xFF607D8B, "color": COLORS['text_primary'], "border_radius": 13})
                                                    ui.Button("Weathered Steel", 
                                                             clicked_fn=lambda: self._set_preset("weathered rusty steel"),
                                                             height=26,
                                                             style={"background_color": 0xFF8D6E63, "color": COLORS['text_primary'], "border_radius": 13})
                                                
                                                # Row 2: More metals
                                                with ui.HStack(spacing=8):
                                                    ui.Button("Bright Gold", 
                                                             clicked_fn=lambda: self._set_preset("bright gold metal"),
                                                             height=26,
                                                             style={"background_color": 0xFFB8860B, "color": COLORS['text_primary'], "border_radius": 13})
                                                    ui.Button("Aged Brass", 
                                                             clicked_fn=lambda: self._set_preset("aged brass with green patina"),
                                                             height=26,
                                                             style={"background_color": 0xFFB8860B, "color": COLORS['text_primary'], "border_radius": 13})
                                                
                                                # Row 3: Bright colors
                                                with ui.HStack(spacing=8):
                                                    ui.Button("Bright Red", 
                                                             clicked_fn=lambda: self._set_preset("bright red paint"),
                                                             height=26,
                                                             style={"background_color": 0xFFF44336, "color": COLORS['text_primary'], "border_radius": 13})
                                                    ui.Button("Bright Blue", 
                                                             clicked_fn=lambda: self._set_preset("bright blue paint"),
                                                             height=26,
                                                             style={"background_color": 0xFF2196F3, "color": COLORS['text_primary'], "border_radius": 13})
                                                
                                                # Row 4: More colors
                                                with ui.HStack(spacing=8):
                                                    ui.Button("Bright Green", 
                                                             clicked_fn=lambda: self._set_preset("bright green paint"),
                                                             height=26,
                                                             style={"background_color": 0xFF4CAF50, "color": COLORS['text_primary'], "border_radius": 13})
                                                    ui.Button("Bright Yellow", 
                                                             clicked_fn=lambda: self._set_preset("bright yellow paint"),
                                                             height=26,
                                                             style={"background_color": 0xFFFFEB3B, "color": 0xFF000000, "border_radius": 13})
                                            ui.Spacer(width=15)
                                        
                                        # Generation Settings
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            with ui.HStack(spacing=15):
                                                ui.Label("Generation Mode:", style={"color": COLORS['text_primary']})
                                                self._fast_mode_btn = ui.Button("Fast Mode: ON", 
                                                                               clicked_fn=self._toggle_fast_mode,
                                                                               width=110, height=26,
                                                                               style={"background_color": COLORS['warning'],
                                                                                     "color": COLORS['text_primary'],
                                                                                     "border_radius": 13})
                                                ui.Spacer()
                                            ui.Spacer(width=15)
                                        
                                        # Initialize fast mode
                                        self._fast_mode = True
                                        
                                        # Generate Button
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            ui.Button("Generate Material with FLUX.1", 
                                                     clicked_fn=self._on_generate_clicked, 
                                                     height=40,
                                                     style={"background_color": COLORS['primary'], 
                                                           "color": COLORS['text_primary'],
                                                           "font_size": 15,
                                                           "border_radius": 20})
                                            ui.Spacer(width=15)
                                        
                                        # Status
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            self._status_label = ui.Label("Ready! Select objects and generate materials", 
                                                                         style={"color": COLORS['text_secondary'], "font_size": 11})
                                            ui.Spacer(width=15)
                                        
                                        ui.Spacer(height=8)
                            ui.Spacer(width=20)
                        
                        # RESULTS CARD
                        with ui.HStack():
                            ui.Spacer(width=20)
                            with ui.VStack(spacing=0):
                                # Card Header
                                with ui.Frame(height=40, style={"background_color": COLORS['secondary'], "border_radius": 8}):
                                    with ui.HStack():
                                        ui.Spacer(width=15)
                                        ui.Label("Last Generated Material", 
                                                style={"font_size": 16, "color": COLORS['text_primary']})
                                        ui.Spacer()
                                
                                # Card Content
                                with ui.Frame(style={"background_color": COLORS['surface'], "border_radius": 8}):
                                    with ui.VStack(spacing=6):
                                        ui.Spacer(height=8)
                                        
                                        with ui.HStack():
                                            ui.Spacer(width=15)
                                            with ui.VStack(spacing=8):
                                                # Material Properties Grid
                                                with ui.HStack(spacing=30):
                                                    with ui.VStack(spacing=5):
                                                        ui.Label("Metallic", style={"color": COLORS['text_secondary'], "font_size": 11})
                                                        self._metallic_label = ui.Label("--", style={"color": COLORS['text_primary'], "font_size": 14})
                                                    with ui.VStack(spacing=5):
                                                        ui.Label("Roughness", style={"color": COLORS['text_secondary'], "font_size": 11})
                                                        self._roughness_label = ui.Label("--", style={"color": COLORS['text_primary'], "font_size": 14})
                                                    ui.Spacer()
                                                
                                                with ui.HStack(spacing=5):
                                                    ui.Label("Color:", style={"color": COLORS['text_secondary'], "font_size": 11})
                                                    self._color_label = ui.Label("--", style={"color": COLORS['text_primary'], "font_size": 12})
                                                
                                                with ui.HStack(spacing=30):
                                                    with ui.VStack(spacing=5):
                                                        ui.Label("Generation Time", style={"color": COLORS['text_secondary'], "font_size": 11})
                                                        self._generation_time_label = ui.Label("--", style={"color": COLORS['text_primary'], "font_size": 12})
                                                    with ui.VStack(spacing=5):
                                                        ui.Label("Method", style={"color": COLORS['text_secondary'], "font_size": 11})
                                                        self._method_label = ui.Label("--", style={"color": COLORS['text_primary'], "font_size": 12})
                                                    ui.Spacer()
                                            ui.Spacer(width=15)
                                        
                                        ui.Spacer(height=8)
                            ui.Spacer(width=20)
                        
                        # INSTRUCTIONS CARD
                        with ui.HStack():
                            ui.Spacer(width=20)
                            with ui.VStack(spacing=0):
                                # Card Header
                                with ui.Frame(height=40, style={"background_color": COLORS['secondary'], "border_radius": 8}):
                                    with ui.HStack():
                                        ui.Spacer(width=15)
                                        ui.Label("Quick Start Guide", 
                                                style={"font_size": 16, "color": COLORS['text_primary']})
                                        ui.Spacer()
                                
                                # Card Content
                                with ui.Frame(style={"background_color": COLORS['surface'], "border_radius": 8}):
                                    with ui.VStack(spacing=6):
                                        ui.Spacer(height=8)
                                        
                                        instructions = [
                                            "1. Enter your NVCF API key above",
                                            "2. Select 3D objects in the viewport",
                                            "3. Choose FLUX.1-dev or FLUX.1-schnell model",
                                            "4. Describe your material or use presets",
                                            "5. Click Generate Material with FLUX.1",
                                            "6. Materials will be applied automatically"
                                        ]
                                        
                                        for instruction in instructions:
                                            with ui.HStack():
                                                ui.Spacer(width=15)
                                                ui.Label(instruction, 
                                                        style={"color": COLORS['text_secondary'], "font_size": 11})
                                                ui.Spacer(width=15)
                                        
                                        ui.Spacer(height=8)
                            ui.Spacer(width=20)
                        
                        ui.Spacer(height=15)
    
    def _toggle_fast_mode(self):
        """Toggle fast mode on/off"""
        self._fast_mode = not self._fast_mode
        mode_text = "ON" if self._fast_mode else "OFF"
        color = 0xFFFF9800 if self._fast_mode else 0xFF607D8B  # Orange for ON, Blue-gray for OFF
        self._fast_mode_btn.text = f"Fast Mode: {mode_text}"
        # Update button style
        self._fast_mode_btn.style = {
            "background_color": color,
            "color": 0xFFFFFFFF,
            "border_radius": 13
        }
        print(f"Fast mode: {mode_text}")
    
    def _browse_ngc(self):
        """Simulate browsing NGC catalog"""
        self._status_label.text = "Browse NGC catalog at https://catalog.ngc.nvidia.com"
        self._status_label.style = {"color": 0xFF81C784, "font_size": 11}  # Light green
        print("Navigate to NGC catalog to explore available foundation models")
    
    def _set_preset(self, preset_text):
        """Set a preset material description"""
        self._material_input.model.set_value(preset_text)
        self._status_label.text = f"Preset applied: {preset_text}"
        self._status_label.style = {"color": 0xFF4CAF50, "font_size": 11}  # Success green
        print(f"Set NVCF preset: {preset_text}")
    
    def _test_connection(self):
        """Test connection to NVCF endpoint"""
        self._connection_status.text = "Testing..."
        self._connection_status.style = {"font_size": 12, "color": 0xFFFF9800}  # Orange
        endpoint = self._endpoint_input.model.get_value_as_string()
        api_key = self._api_key_input.model.get_value_as_string()
        asyncio.ensure_future(self._test_nvcf_async(endpoint, api_key))
    
    async def _test_nvcf_async(self, endpoint: str, api_key: str):
        """Test NVCF endpoint"""
        try:
            if not api_key or api_key == "nvapi-xxx":
                self._connection_status.text = "API Key Required"
                self._connection_status.style = {"font_size": 12, "color": 0xFFF44336}  # Red
                return
                
            headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
            timeout = aiohttp.ClientTimeout(total=10)
            
            async with aiohttp.ClientSession(timeout=timeout) as session:
                test_url = "https://api.nvcf.nvidia.com/v2/nvcf/functions"
                async with session.post(test_url, json={"test": "connection"}, headers=headers) as response:
                    if response.status == 200:
                        self._connection_status.text = "Connected"
                        self._connection_status.style = {"font_size": 12, "color": 0xFF4CAF50}  # Green
                        print("NVCF connection successful")
                    elif response.status == 401:
                        self._connection_status.text = "Invalid API Key"
                        self._connection_status.style = {"font_size": 12, "color": 0xFFF44336}  # Red
                    else:
                        self._connection_status.text = f"HTTP {response.status}"
                        self._connection_status.style = {"font_size": 12, "color": 0xFFF44336}  # Red
        except Exception as e:
            error_msg = str(e)[:15] + "..." if len(str(e)) > 15 else str(e)
            self._connection_status.text = f"Error: {error_msg}"
            self._connection_status.style = {"font_size": 12, "color": 0xFFF44336}  # Red
            print(f"NVCF connection failed: {e}")
    
    def _on_generate_clicked(self):
        """Handle the generate button click"""
        # Rate limiting
        current_time = time.time()
        if current_time - self._last_request_time < 2.0:
            self._status_label.text = "Please wait 2 seconds between requests"
            self._status_label.style = {"color": 0xFFFF9800, "font_size": 11}  # Orange warning
            return
        
        # Check if objects are selected
        context = omni.usd.get_context()
        selection = context.get_selection()
        selected_paths = selection.get_selected_prim_paths()
        
        if not selected_paths:
            self._status_label.text = "Please select objects in the viewport first!"
            self._status_label.style = {"color": 0xFFF44336, "font_size": 11}  # Red error
            return
        
        # Get inputs
        description = self._material_input.model.get_value_as_string().strip()
        if not description:
            self._status_label.text = "Please enter a material description"
            self._status_label.style = {"color": 0xFFF44336, "font_size": 11}  # Red error
            return
        
        endpoint = self._endpoint_input.model.get_value_as_string().strip()
        api_key = self._api_key_input.model.get_value_as_string().strip()
        
        # Check if we should use demo mode or try NVCF
        use_demo_mode = (not api_key or api_key == "nvapi-xxx")
        
        self._last_request_time = current_time
        
        if use_demo_mode:
            self._status_label.text = f"Generating demo material for {len(selected_paths)} objects..."
            self._status_label.style = {"color": 0xFF81C784, "font_size": 11}  # Light green
            # Use demo mode immediately
            self._create_demo_material(description, selected_paths)
        else:
            self._status_label.text = f"Generating via FLUX.1 for {len(selected_paths)} objects..."
            self._status_label.style = {"color": 0xFF81C784, "font_size": 11}  # Light green
            # Start async NVCF generation
            asyncio.ensure_future(self._generate_nvcf_material_async(description, endpoint, api_key, selected_paths))
    
    async def _generate_nvcf_material_async(self, description: str, endpoint: str, api_key: str, selected_paths: list):
        """Generate material using NVCF"""
        start_time = time.time()
        
        try:
            print(f"🔄 Starting NVCF request...")
            
            headers = {
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json"
            }
            
            enhanced_prompt = f"Material texture: {description}, PBR properties, photorealistic, vibrant colors, NOT grayscale"
            
            payload = {
                "prompt": enhanced_prompt,
                "seed": 42,
                "steps": 20 if self._fast_mode else 40
            }
            
            print(f"📤 FLUX.1 prompt: {enhanced_prompt}")
            
            timeout = aiohttp.ClientTimeout(total=120)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(endpoint, json=payload, headers=headers) as response:
                    print(f"📥 Response status: {response.status}")
                    
                    if response.status == 200:
                        try:
                            result = await response.json()
                            print(f"✅ FLUX.1 Response parsed successfully")
                            
                            image_data = None
                            if "artifacts" in result and len(result["artifacts"]) > 0:
                                image_data = result["artifacts"][0].get("base64")
                            elif "data" in result and len(result["data"]) > 0:
                                image_data = result["data"][0].get("b64_json")
                            elif "images" in result and len(result["images"]) > 0:
                                image_data = result["images"][0]
                            
                            if image_data:
                                print(f"🖼️ Got FLUX.1 image data, length: {len(image_data)} chars")
                                
                                material_props = self._extract_material_properties(image_data, description)
                                material_path = self._create_usd_material(material_props, description)
                                success_count = self._apply_material_to_objects(material_path, selected_paths)
                                
                                generation_time = time.time() - start_time
                                self._update_results_display(material_props, generation_time)
                                
                                self._status_label.text = f"✅ Applied FLUX.1 material to {success_count} objects!"
                                self._status_label.style = {"color": 0xFF4CAF50, "font_size": 11}  # Success green
                                print(f"✅ Successfully applied FLUX.1 material: {description}")
                                return
                            else:
                                print("❌ No image data in FLUX.1 response")
                                
                        except json.JSONDecodeError as e:
                            print(f"❌ Failed to parse JSON response: {e}")
                    else:
                        print(f"❌ FLUX.1 HTTP error: {response.status}")
                            
        except Exception as e:
            print(f"❌ FLUX.1 endpoint failed: {e}")
        
        # Fallback to demo mode
        print("🔄 FLUX.1 unavailable, falling back to demo mode")
        self._create_demo_material(description, selected_paths)
    
    def _extract_material_properties(self, image_data: str, description: str) -> dict:
        """Extract material properties from FLUX.1 generated image using CV analysis"""
        try:
            # Try CV analysis first
            return self._analyze_material_properties_cv(image_data, description)
        except Exception as e:
            print(f"CV analysis failed, using rule-based fallback: {e}")
            return self._analyze_material_by_description(description)
    
    def _analyze_material_properties_cv(self, image_data: str, description: str) -> dict:
        """Computer vision analysis of FLUX.1 generated material texture"""
        try:
            import base64
            import io
            
            # Try to import CV libraries
            try:
                from PIL import Image
                import numpy as np
            except ImportError:
                print("PIL/numpy not available, falling back to rule-based analysis")
                return self._analyze_material_by_description(description)
            
            # Decode image from FLUX.1 response
            if isinstance(image_data, str):
                image_bytes = base64.b64decode(image_data)
            else:
                image_bytes = image_data
            
            # Load and analyze image
            image = Image.open(io.BytesIO(image_bytes)).convert('RGB')
            image_array = np.array(image)
            
            print(f"🖼️ Analyzing FLUX.1 image: {image.size}")
            
            # Extract dominant color from multiple regions
            h, w = image_array.shape[:2]
            regions = [
                image_array[h//4:3*h//4, w//4:3*w//4],  # Center
                image_array[:h//2, :w//2],              # Top-left
                image_array[h//2:, w//2:]               # Bottom-right
            ]
            
            region_colors = []
            for region in regions:
                if region.size > 0:
                    median_color = np.median(region.reshape(-1, 3), axis=0) / 255.0
                    region_colors.append(median_color)
            
            if not region_colors:
                base_color = [0.5, 0.5, 0.5]
            else:
                # Find most saturated color
                best_color = region_colors[0]
                best_saturation = 0
                
                for color in region_colors:
                    r, g, b = color
                    max_val = max(r, g, b)
                    min_val = min(r, g, b)
                    saturation = (max_val - min_val) / max_val if max_val > 0 else 0
                    
                    if saturation > best_saturation:
                        best_color = color
                        best_saturation = saturation
                
                # Enhance saturation for visibility
                r, g, b = best_color
                if best_saturation < 0.5:
                    # Boost the dominant channel
                    max_val = max(r, g, b)
                    if r == max_val:
                        r = min(1.0, r * 1.5)
                    elif g == max_val:
                        g = min(1.0, g * 1.5)
                    else:
                        b = min(1.0, b * 1.5)
                
                base_color = [r, g, b]
            
            # Apply description hints for color override
            description_lower = description.lower()
            if 'bright red' in description_lower:
                base_color = [1.0, 0.1, 0.1]
            elif 'bright green' in description_lower:
                base_color = [0.1, 1.0, 0.1]
            elif 'bright blue' in description_lower:
                base_color = [0.1, 0.1, 1.0]
            elif 'red' in description_lower and base_color[0] < 0.6:
                base_color[0] = min(1.0, base_color[0] * 2.0)
            elif 'green' in description_lower and base_color[1] < 0.6:
                base_color[1] = min(1.0, base_color[1] * 2.0)
            elif 'blue' in description_lower and base_color[2] < 0.6:
                base_color[2] = min(1.0, base_color[2] * 2.0)
            
            # Analyze roughness from texture variation
            luminance = 0.299 * image_array[:,:,0] + 0.587 * image_array[:,:,1] + 0.114 * image_array[:,:,2]
            grad_x = np.gradient(luminance, axis=1)
            grad_y = np.gradient(luminance, axis=0)
            gradient_magnitude = np.sqrt(grad_x**2 + grad_y**2)
            roughness = np.mean(gradient_magnitude) / 120.0
            roughness = max(0.05, min(0.95, roughness))
            
            # Detect metallic properties
            brightness = np.mean(image_array) / 255.0
            gray = np.mean(image_array, axis=2)
            contrast = np.std(gray) / 255.0
            
            metallic_score = 0.0
            if contrast > 0.15:  # High contrast suggests reflective
                metallic_score += 0.4
            if best_saturation < 0.35:  # Low saturation suggests metallic
                metallic_score += 0.3
            
            # Description hints
            if any(metal in description_lower for metal in ["metal", "steel", "chrome", "brass"]):
                metallic_score += 0.6
            elif any(non_metal in description_lower for non_metal in ["paint", "plastic", "wood"]):
                metallic_score -= 0.2
            
            metallic_score = max(0.0, min(1.0, metallic_score))
            
            print(f"🎨 CV Analysis: color={base_color}, metallic={metallic_score:.2f}, roughness={roughness:.2f}")
            
            return {
                "base_color": base_color,
                "metallic": metallic_score,
                "roughness": roughness,
                "generation_method": "cv_analysis"
            }
            
        except Exception as e:
            print(f"❌ CV analysis failed: {e}")
            return self._analyze_material_by_description(description)
    
    def _analyze_material_by_description(self, description: str) -> dict:
        """Analyze material by description with bright colors"""
        description_lower = description.lower()
        
        metallic = 0.0
        roughness = 0.5
        base_color = [0.5, 0.5, 0.5]
        
        # Bright color detection
        if any(word in description_lower for word in ["red", "crimson"]):
            base_color = [1.0, 0.0, 0.0]
        elif any(word in description_lower for word in ["green", "emerald"]):
            base_color = [0.0, 1.0, 0.0]
        elif any(word in description_lower for word in ["blue", "azure"]):
            base_color = [0.0, 0.0, 1.0]
        elif any(word in description_lower for word in ["yellow", "gold"]):
            base_color = [1.0, 1.0, 0.0]
        elif any(word in description_lower for word in ["purple", "violet"]):
            base_color = [1.0, 0.0, 1.0]
        elif any(word in description_lower for word in ["orange"]):
            base_color = [1.0, 0.5, 0.0]
        elif any(word in description_lower for word in ["pink"]):
            base_color = [1.0, 0.4, 0.7]
        elif any(word in description_lower for word in ["white"]):
            base_color = [0.95, 0.95, 0.95]
        elif any(word in description_lower for word in ["black"]):
            base_color = [0.1, 0.1, 0.1]
        
        # Material type detection
        if any(word in description_lower for word in ["chrome", "polished", "mirror"]):
            metallic = 0.95
            roughness = 0.05
            base_color = [0.9, 0.9, 0.95]
        elif any(word in description_lower for word in ["rust", "weathered"]):
            metallic = 0.1
            roughness = 0.8
            base_color = [0.8, 0.2, 0.1]
        elif any(word in description_lower for word in ["metal", "steel"]):
            metallic = 0.8
            roughness = 0.3
        elif any(word in description_lower for word in ["gold", "brass"]):
            metallic = 0.9
            roughness = 0.2
            base_color = [0.9, 0.7, 0.2]
        elif any(word in description_lower for word in ["plastic", "paint"]):
            metallic = 0.0
            roughness = 0.4
        
        return {
            "base_color": base_color,
            "metallic": metallic,
            "roughness": roughness,
            "generation_method": "description_analysis"
        }
    
    def _create_usd_material(self, material_props: dict, description: str) -> str:
        """Create USD material"""
        context = omni.usd.get_context()
        stage = context.get_stage()
        
        timestamp = int(time.time())
        material_path = f"/World/Materials/FLUX1Material_{timestamp}"
        
        print(f"🔧 Creating material: {material_path}")
        
        material = UsdShade.Material.Define(stage, material_path)
        shader_path = material_path + "/Shader"
        shader = UsdShade.Shader.Define(stage, shader_path)
        shader.CreateIdAttr("UsdPreviewSurface")
        
        metallic = float(material_props.get("metallic", 0.0))
        roughness = float(material_props.get("roughness", 0.5))
        base_color = material_props.get("base_color", [0.5, 0.5, 0.5])
        
        print(f"🎨 Material: color={base_color}, metallic={metallic:.2f}, roughness={roughness:.2f}")
        
        color_vec = Gf.Vec3f(float(base_color[0]), float(base_color[1]), float(base_color[2]))
        
        shader.CreateInput("baseColor", Sdf.ValueTypeNames.Color3f).Set(color_vec)
        shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(color_vec)
        shader.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(metallic)
        shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(roughness)
        shader.CreateInput("specular", Sdf.ValueTypeNames.Float).Set(0.5)
        shader.CreateInput("opacity", Sdf.ValueTypeNames.Float).Set(1.0)
        
        material.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
        material.GetPrim().SetMetadata("comment", f"FLUX.1 Generated: {description}")
        
        print(f"✅ Created material: {material_path}")
        return material_path
    
    def _apply_material_to_objects(self, material_path: str, object_paths: list) -> int:
        """Apply material to objects"""
        context = omni.usd.get_context()
        stage = context.get_stage()
        
        material = UsdShade.Material.Get(stage, material_path)
        if not material:
            print(f"❌ Could not find material: {material_path}")
            return 0
        
        print(f"🔧 Applying material to {len(object_paths)} objects")
        
        success_count = 0
        for prim_path in object_paths:
            try:
                prim = stage.GetPrimAtPath(prim_path)
                if prim.IsValid():
                    # Clear existing bindings
                    if prim.HasAPI(UsdShade.MaterialBindingAPI):
                        binding_api = UsdShade.MaterialBindingAPI(prim)
                        binding_api.UnbindAllBindings()
                    
                    # Apply new binding
                    binding_api = UsdShade.MaterialBindingAPI.Apply(prim)
                    binding_api.Bind(material, UsdShade.Tokens.strongerThanDescendants)
                    
                    print(f"✅ Applied material to: {prim_path}")
                    success_count += 1
                else:
                    print(f"❌ Invalid prim: {prim_path}")
            except Exception as e:
                print(f"❌ Error applying material to {prim_path}: {e}")
        
        # Force viewport refresh
        self._force_viewport_refresh()
        
        return success_count
    
    def _force_viewport_refresh(self):
        """Force viewport refresh"""
        try:
            context = omni.usd.get_context()
            stage = context.get_stage()
            stage.Reload()
            
            try:
                import omni.kit.commands
                omni.kit.commands.execute('Refresh')
            except:
                pass
            
            print("🔄 Forced viewport refresh")
        except Exception as e:
            print(f"⚠️ Could not refresh viewport: {e}")
    
    def _update_results_display(self, result: dict, generation_time: float):
        """Update the results display in UI"""
        metallic = result.get("metallic", 0.0)
        roughness = result.get("roughness", 0.5)
        base_color = result.get("base_color", [0.5, 0.5, 0.5])
        method = result.get("generation_method", "unknown")
        
        self._metallic_label.text = f"{metallic:.3f}"
        self._roughness_label.text = f"{roughness:.3f}"
        self._color_label.text = f"({base_color[0]:.2f}, {base_color[1]:.2f}, {base_color[2]:.2f})"
        self._generation_time_label.text = f"{generation_time:.2f}s"
        self._method_label.text = f"{method}"
    
    def _create_demo_material(self, description: str, selected_paths: list):
        """Create demo material"""
        try:
            print(f"🎨 Creating demo material: {description}")
            
            material_props = self._analyze_material_by_description(description)
            material_path = self._create_usd_material(material_props, f"Demo: {description}")
            success_count = self._apply_material_to_objects(material_path, selected_paths)
            
            self._update_results_display(material_props, 0.1)
            self._status_label.text = f"✅ Applied demo material to {success_count} objects!"
            self._status_label.style = {"color": 0xFF4CAF50, "font_size": 11}  # Success green
            
            print(f"✅ Demo material applied to {success_count} objects")
            
        except Exception as e:
            self._status_label.text = f"❌ Demo error: {str(e)[:30]}..."
            self._status_label.style = {"color": 0xFFF44336, "font_size": 11}  # Red error
            print(f"❌ Error in demo material: {e}")

# ============================================================================
# AUTO-LOAD EXTENSION
# ============================================================================

# Destroy old extension if it exists
try:
    if 'dgx_extension' in globals():
        dgx_extension.on_shutdown()
        print("🗑️ Destroyed old extension")
except:
    pass

# Create new extension
print("🚀 Creating DGX Cloud NVCF Material Extension with Polished UI...")
dgx_extension = DGXNVCFMaterialExtension()
dgx_extension.on_startup("script_editor")

# Helper functions
def show_dgx_nvcf():
    """Show extension window"""
    dgx_extension.show_window()

def hide_dgx_nvcf():
    """Hide extension window"""
    dgx_extension.hide_window()

def toggle_dgx_nvcf():
    """Toggle extension window"""
    dgx_extension.toggle_window()

def reload_dgx_nvcf():
    """Reload extension"""
    global dgx_extension
    try:
        dgx_extension.on_shutdown()
    except:
        pass
    dgx_extension = DGXNVCFMaterialExtension()
    dgx_extension.on_startup("script_editor")
    print("🔄 Extension reloaded!")

def debug_materials():
    """Debug material system"""
    print("🔍 === MATERIAL DEBUG ===")
    
    context = omni.usd.get_context()
    stage = context.get_stage()
    
    materials_prim = stage.GetPrimAtPath("/World/Materials")
    if materials_prim:
        print(f"📁 Materials folder exists")
        for child in materials_prim.GetChildren():
            if child.IsA(UsdShade.Material):
                print(f"🎨 Material: {child.GetPath()}")
    else:
        print(f"❌ No materials folder")
    
    selection = context.get_selection()
    selected_paths = selection.get_selected_prim_paths()
    print(f"📦 Selected objects: {len(selected_paths)}")
    
    for path in selected_paths:
        prim = stage.GetPrimAtPath(path)
        if prim and prim.HasAPI(UsdShade.MaterialBindingAPI):
            binding_api = UsdShade.MaterialBindingAPI(prim)
            binding_rel = binding_api.GetDirectBindingRel()
            if binding_rel:
                targets = binding_rel.GetTargets()
                print(f"   📦 {path} -> {targets}")
            else:
                print(f"   📦 {path} -> No materials")
        else:
            print(f"   📦 {path} -> No binding API")
    
    print("🔍 === END DEBUG ===")

# Success message
print("✅ DGX Cloud NVCF Extension with Polished UI loaded successfully!")
print("")
print("🎮 Commands:")
print("  show_dgx_nvcf()    - Show window")
print("  hide_dgx_nvcf()    - Hide window") 
print("  toggle_dgx_nvcf()  - Toggle window")
print("  reload_dgx_nvcf()  - Reload extension")
print("  debug_materials()  - Debug materials")
print("")
print("🎯 Ready! Select objects and generate bright materials!")
print("💡 Works in demo mode or with FLUX.1 API key")
print("")
print("🔧 FEATURES:")
print("  ✅ Beautiful card-based UI design")
print("  ✅ Bright, visible colors in demo mode")
print("  ✅ FLUX.1 NVCF integration")
print("  ✅ Strong material binding")
print("  ✅ Automatic viewport refresh")
print("  ✅ 8 color + metal presets")
print("  ✅ Debug tools")
print("  ✅ Professional styling with proper spacing")