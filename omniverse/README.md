# DGX Cloud NVCF Material Extension

🚀 **AI-Powered Material Generation for NVIDIA Omniverse using DGX Cloud NVCF**

A comprehensive Omniverse extension that leverages **NVIDIA DGX Cloud**'s **NVCF (NVIDIA Cloud Functions)** platform to generate photorealistic materials using AI foundation models. Create stunning PBR materials from natural language descriptions with support for both real DGX Cloud NVCF endpoints and demo mode.

**DGX Cloud** is NVIDIA's enterprise AI platform that provides on-demand access to AI infrastructure, including NVCF for serverless AI inference and model serving.

## ✨ Features

- **🤖 AI Material Generation**: Generate materials from natural language descriptions
- **☁️ DGX Cloud NVCF Integration**: Full support for NVIDIA DGX Cloud's NVCF platform
- **🎨 FLUX.1 Foundation Models**: Support for FLUX.1-dev, FLUX.1-schnell, and custom models
- **🔍 Computer Vision Analysis**: Automatic extraction of material properties from generated textures
- **⚡ Fast Mode**: Optimized generation with reduced inference steps
- **🎯 Quick Presets**: 8 pre-built material descriptions for common materials
- **📊 Real-time Results**: Live display of generated material properties
- **🔄 Demo Mode**: Test functionality without NVCF service
- **🎮 Easy Commands**: Simple functions to show/hide/toggle the extension
- **🎨 Polished UI**: Beautiful card-based interface with professional styling
- **👁️ Visible Materials**: Materials now properly display in Omniverse viewport

## 🎯 Supported Materials

- **✨ Polished Chrome**: Clean reflective surfaces
- **🦀 Weathered Steel**: Rusty, corroded metal
- **🥉 Bright Gold**: Shiny gold metal
- **🥉 Aged Brass**: Patinated brass with green oxidation
- **🔴 Bright Red**: Vibrant red paint
- **🔵 Bright Blue**: Vibrant blue paint
- **🟢 Bright Green**: Vibrant green paint
- **🟡 Bright Yellow**: Vibrant yellow paint
- **🔧 Custom Materials**: Any material describable in natural language

## 📋 Requirements

- **NVIDIA Omniverse** (latest version)
- **Python 3.7+** (included with Omniverse)
- **DGX Cloud NVCF API Key** (optional - demo mode available)
- **Internet Connection** (for DGX Cloud NVCF calls)

### **Dependencies Installation**

The extension requires several Python packages for full functionality. Install them using the provided `requirements.txt`:

```bash
# Install all required dependencies
pip install -r requirements.txt
```

**Required Dependencies:**
- `aiohttp>=3.8.0` - Async HTTP client for NVCF API communication
- `Pillow>=9.0.0` - Image processing for computer vision analysis
- `numpy>=1.21.0` - Numerical computing for material property analysis

**Optional Dependencies:**
- `scipy>=1.7.0` - Advanced image processing for texture pattern recognition
- `scikit-image>=0.19.0` - Enhanced image analysis capabilities

**Note:** Omniverse-specific dependencies (`pxr`, `omni.ext`, `omni.ui`, `omni.usd`, etc.) are provided by the Omniverse environment and don't need to be installed separately.

## 🚀 Installation

1. **Download the Extension**:
   ```bash
   git clone https://gitlab-master.nvidia.com/dgxc-tme/dgxc-omniverse-material-gen.git
   cd dgxc-omniverse-material-gen
   ```

2. **Install Dependencies** (if not using Omniverse's built-in environment):
   ```bash
   pip install -r requirements.txt
   ```

3. **Load in Omniverse**:
   - Open NVIDIA Omniverse
   - Navigate to the Script Editor
   - Copy and paste the contents of `dgx_omni_ext.py`
   - Execute the script

4. **Alternative Loading**:
   ```python
   exec(open("path/to/dgx_omni_ext.py").read())
   ```

## 🎮 Usage

### Basic Workflow

1. **Open the Extension**:
   ```python
   show_dgx_nvcf()
   ```

2. **Configure DGX Cloud NVCF** (optional):
   - Enter your DGX Cloud NVCF API endpoint
   - Add your DGX Cloud API key
   - Test the connection

3. **Create Objects**:
   - Create or import 3D objects in Omniverse
   - Select the objects you want to materialize

4. **Generate Materials**:
   - Enter a material description or use presets
   - Choose your foundation model (FLUX.1-dev, FLUX.1-schnell, Custom)
   - Click "Generate Material with FLUX.1"

### Available Commands

```python
# Show the extension window
show_dgx_nvcf()

# Hide the extension window
hide_dgx_nvcf()

# Toggle window visibility
toggle_dgx_nvcf()

# Reload the extension
reload_dgx_nvcf()

# Debug material system
debug_materials()
```

### Material Generation Examples

```python
# Generate polished chrome
material_description = "polished chrome metal"

# Generate weathered steel
material_description = "weathered rusty steel"

# Generate bright red paint
material_description = "bright red paint"

# Generate bright blue paint
material_description = "bright blue paint"
```

## 🔧 Configuration

### DGX Cloud NVCF Settings

- **API Endpoint**: `https://api.nvcf.nvidia.com/v2/nvcf/pexec/functions/d068db74-322f-40a7-bc19-9113ff0efdc6`
- **API Key**: Your DGX Cloud NVCF API key (format: `nvapi-xxx`)
- **Function ID**: Your specific FLUX.1 material generation function ID

### Generation Modes

- **⚡ Fast Mode**: 20 inference steps, faster generation
- **🎨 Quality Mode**: 40 inference steps, higher quality results

### Foundation Models

- **FLUX.1-dev**: High-quality, detailed materials
- **FLUX.1-schnell**: Balanced quality and speed
- **Custom Model**: Use your own trained model

## 🧠 How It Works

### 1. Material Description Processing
The extension takes natural language descriptions and optimizes them for AI generation:
```
Input: "bright red paint"
Output: "Material texture: bright red paint, PBR properties, photorealistic, vibrant colors, NOT grayscale"
```

### 2. DGX Cloud NVCF Integration
- Sends requests to NVIDIA DGX Cloud's NVCF platform using FLUX.1
- Supports multiple foundation models
- Handles authentication and rate limiting

### 3. Computer Vision Analysis
When DGX Cloud NVCF returns generated textures, the extension:
- Analyzes image properties using computer vision
- Extracts dominant colors with enhanced saturation
- Calculates surface roughness from texture variation
- Detects metallic properties from contrast and saturation
- Applies aggressive color boosting for visibility

### 4. USD Material Creation
- Creates proper USD materials with PBR properties
- Applies materials to selected objects with strong binding
- Maintains metadata for tracking
- Forces viewport refresh for immediate visibility

### 5. Fallback System
If DGX Cloud NVCF is unavailable:
- Uses rule-based material analysis
- Provides demo mode functionality
- Ensures the extension always works

## 📊 Material Properties

The extension generates and displays:

- **Metallic**: 0.0 (non-metallic) to 1.0 (fully metallic)
- **Roughness**: 0.0 (mirror-like) to 1.0 (completely rough)
- **Base Color**: RGB values for material tint
- **Generation Time**: Performance metrics
- **Method**: Source of material properties (DGX Cloud NVCF CV, rule-based, etc.)

## 🔍 Troubleshooting

### Common Issues

1. **"Please select objects in the viewport first!"**
   - Solution: Select 3D objects before generating materials

2. **"API Key Required"**
   - Solution: Enter a valid DGX Cloud NVCF API key or use demo mode

3. **"Please wait 2 seconds between requests"**
   - Solution: Wait for rate limiting to reset

4. **Extension window not showing**
   - Solution: Run `show_dgx_nvcf()` in the Script Editor

5. **Materials not visible in viewport**
   - Solution: Use `debug_materials()` to check material bindings
   - The extension now includes automatic viewport refresh

### Demo Mode

If you don't have DGX Cloud NVCF access:
- Leave API key as `nvapi-xxx`
- The extension will automatically use demo mode
- All functionality works with rule-based material generation
- Bright colors are now properly visible in the viewport

## 🛠️ Development

### Architecture

The extension is built with:
- **Omniverse UI Framework**: Native Omniverse interface with polished styling
- **USD (Universal Scene Description)**: Material and scene management
- **Async/Await**: Non-blocking NVCF calls
- **Computer Vision**: PIL/numpy for image analysis
- **Error Handling**: Graceful fallbacks and user feedback
- **Viewport Integration**: Proper material binding and refresh

### Extending the Extension

To add new features:

1. **New Material Types**:
   ```python
   def _analyze_material_by_description(self, description: str) -> dict:
       # Add new material rules here
   ```

2. **New Foundation Models**:
   ```python
   models = ["FLUX.1-dev", "FLUX.1-schnell", "your-custom-model"]
   ```

3. **New UI Elements**:
   ```python
   # Add to _create_ui() method
   ui.Button("New Feature", clicked_fn=self._new_feature)
   ```

## 📈 Performance

- **Generation Time**: 0.1s (demo) to 30s (DGX Cloud NVCF)
- **Memory Usage**: Minimal overhead
- **Rate Limiting**: 2-second minimum between requests
- **Error Recovery**: Automatic fallback to demo mode
- **Viewport Refresh**: Immediate material visibility

## 🤝 Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly in Omniverse
5. Submit a merge request

### Development Setup

```bash
# Clone the repository
git clone https://gitlab-master.nvidia.com/dgxc-tme/dgxc-omniverse-material-gen.git

# Load in Omniverse for testing
exec(open("dgx_omni_ext.py").read())
```

## 📄 License

This project is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.

The Apache License 2.0 is a permissive license that allows for:
- Commercial use
- Modification
- Distribution
- Private use
- Patent protection
- Clear attribution requirements

While providing liability protection for the authors and contributors.

## 🙏 Acknowledgments

- **NVIDIA Omniverse Team**: For the amazing platform
- **NVIDIA DGX Cloud Team**: For the enterprise AI infrastructure
- **NVCF Team**: For cloud function capabilities within DGX Cloud
- **Black Forest Labs**: For FLUX.1 foundation models
- **Open Source Community**: For computer vision libraries

## 📞 Support

- **Issues**: Create an issue in this repository
- **Documentation**: Check this README and inline code comments
- **Community**: NVIDIA Omniverse forums

## 🎉 Recent Updates

- **✅ Working Version**: Materials now properly visible in viewport
- **✅ Polished UI**: Beautiful card-based interface with professional styling
- **✅ FLUX.1 Integration**: Full support for FLUX.1 models
- **✅ Enhanced CV Analysis**: Improved color extraction and material property detection
- **✅ Strong Material Binding**: Reliable material application to objects
- **✅ Automatic Viewport Refresh**: Immediate visual feedback

---

*Transform your 3D scenes with AI-powered materials!*
