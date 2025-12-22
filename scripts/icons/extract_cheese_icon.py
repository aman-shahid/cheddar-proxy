#!/usr/bin/env python3
"""
Extract the cheese object from the app icon by removing the background.
Crops transparent areas and scales cheese to fill the icon.
Creates a transparent PNG that works with all macOS themes.
"""

from PIL import Image
import os
from collections import deque

def color_distance(c1, c2):
    """Calculate color distance between two RGB tuples."""
    return ((c1[0] - c2[0]) ** 2 + (c1[1] - c2[1]) ** 2 + (c1[2] - c2[2]) ** 2) ** 0.5


def is_grayish(r, g, b, tolerance=25):
    """Check if a color is grayish (R, G, B values are similar)."""
    return abs(r - g) <= tolerance and abs(g - b) <= tolerance and abs(r - b) <= tolerance


def flood_fill_background(image_path, output_path, tolerance=60):
    """
    Remove background using flood fill from corners.
    More accurate for complex backgrounds.
    """
    img = Image.open(image_path).convert('RGBA')
    width, height = img.size
    pixels = img.load()
    
    # Create mask for background (True = background, False = keep)
    background_mask = [[False] * height for _ in range(width)]
    
    # Get background color samples from corners
    corner_positions = [
        (0, 0), (width-1, 0), (0, height-1), (width-1, height-1)
    ]
    
    # BFS flood fill from each corner
    visited = set()
    
    for start_x, start_y in corner_positions:
        start_color = pixels[start_x, start_y][:3]
        
        # Skip if already visited
        if (start_x, start_y) in visited:
            continue
        
        queue = deque([(start_x, start_y)])
        
        while queue:
            x, y = queue.popleft()
            
            if (x, y) in visited:
                continue
            if x < 0 or x >= width or y < 0 or y >= height:
                continue
            
            current = pixels[x, y][:3]
            
            # Check if this pixel is similar to background (grayish and similar color)
            dist = color_distance(current, start_color)
            if dist > tolerance:
                continue
            if not is_grayish(*current, tolerance=30):
                continue
            
            visited.add((x, y))
            background_mask[x][y] = True
            
            # Add neighbors
            for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    if (nx, ny) not in visited:
                        queue.append((nx, ny))
    
    # Create new image with transparent background
    new_img = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    new_pixels = new_img.load()
    
    for x in range(width):
        for y in range(height):
            if background_mask[x][y]:
                new_pixels[x, y] = (0, 0, 0, 0)
            else:
                r, g, b, a = pixels[x, y]
                new_pixels[x, y] = (r, g, b, 255)
    
    # Apply edge antialiasing
    new_img = antialiasing_edges(new_img, background_mask, pixels)
    
    new_img.save(output_path, 'PNG')
    print(f"Saved: {output_path}")
    return new_img


def antialiasing_edges(new_img, background_mask, original_pixels):
    """Apply antialiasing at edges for smooth transition."""
    width, height = new_img.size
    new_pixels = new_img.load()
    
    for x in range(1, width-1):
        for y in range(1, height-1):
            if not background_mask[x][y]:
                # Check if this is an edge pixel (has background neighbors)
                neighbors_bg = 0
                for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]:
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < width and 0 <= ny < height:
                        if background_mask[nx][ny]:
                            neighbors_bg += 1
                
                if neighbors_bg > 0:
                    # This is an edge pixel, apply partial transparency
                    r, g, b, _ = new_pixels[x, y]
                    alpha = 255 - (neighbors_bg * 20)  # More bg neighbors = more transparent
                    alpha = max(128, alpha)  # Don't go too transparent
                    new_pixels[x, y] = (r, g, b, alpha)
    
    return new_img


def crop_to_content(img, padding_percent=5):
    """
    Crop the image to the non-transparent content and add padding.
    Returns a square image with the content centered.
    """
    # Get the bounding box of non-transparent pixels
    bbox = img.getbbox()
    if bbox is None:
        return img  # Image is fully transparent
    
    left, top, right, bottom = bbox
    content_width = right - left
    content_height = bottom - top
    
    print(f"Content bounding box: {bbox} (size: {content_width}x{content_height})")
    
    # Crop to content
    cropped = img.crop(bbox)
    
    # Make it square (use the larger dimension)
    max_dim = max(content_width, content_height)
    
    # Add padding
    padding = int(max_dim * padding_percent / 100)
    final_size = max_dim + (2 * padding)
    
    # Create new square image and paste content centered
    result = Image.new('RGBA', (final_size, final_size), (0, 0, 0, 0))
    
    # Calculate paste position to center
    paste_x = (final_size - content_width) // 2
    paste_y = (final_size - content_height) // 2
    
    result.paste(cropped, (paste_x, paste_y))
    
    print(f"Final icon size: {final_size}x{final_size} (with {padding_percent}% padding)")
    
    return result


def generate_icon_sizes(source_img, output_dir, base_name="app_icon"):
    """Generate all required icon sizes for macOS from the source image."""
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    
    for size in sizes:
        resized = source_img.resize((size, size), Image.Resampling.LANCZOS)
        output_path = os.path.join(output_dir, f"{base_name}_{size}.png")
        resized.save(output_path, 'PNG')
        print(f"Generated: {output_path}")


def main():
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    
    # Check if we have the original backup
    backup_dir = os.path.join(base_dir, "ui/assets/icon/icon_backup")
    original_backup = os.path.join(backup_dir, "original_app_icon_1024.png")
    
    # Input: original 1024px icon (always use the original backup)
    if os.path.exists(original_backup):
        input_path = original_backup
        print(f"Using original backup: {original_backup}")
    else:
        input_path = os.path.join(
            base_dir,
            "ui/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"
        )
        # First time - backup original
        os.makedirs(backup_dir, exist_ok=True)
        import shutil
        shutil.copy(input_path, original_backup)
        print(f"Backed up original icon to: {original_backup}")
    
    # Output directories
    appiconset_dir = os.path.join(
        base_dir,
        "ui/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    )
    assets_icon_dir = os.path.join(base_dir, "ui/assets/icon")
    
    # Process the main icon - remove background
    print("=" * 50)
    print("Step 1: Removing background (flood-fill)...")
    print("=" * 50)
    
    extracted_path = os.path.join(backup_dir, "extracted_cheese_raw.png")
    transparent_img = flood_fill_background(
        input_path,
        extracted_path,
        tolerance=80
    )
    
    print("\n" + "=" * 50)
    print("Step 2: Cropping to content and centering...")
    print("=" * 50)
    
    # Crop to content and scale up with minimal padding
    final_img = crop_to_content(transparent_img, padding_percent=8)
    
    # Scale back to 1024x1024 for high quality
    final_img = final_img.resize((1024, 1024), Image.Resampling.LANCZOS)
    
    final_path = os.path.join(backup_dir, "extracted_cheese_1024.png")
    final_img.save(final_path, 'PNG')
    print(f"Saved final icon: {final_path}")
    
    print("\n" + "=" * 50)
    print("Step 3: Generating all icon sizes...")
    print("=" * 50)
    
    # Generate all sizes for the icon set
    generate_icon_sizes(final_img, appiconset_dir)
    
    # Also update the assets/icon versions
    assets_main = os.path.join(assets_icon_dir, "app_icon.png")
    assets_window = os.path.join(assets_icon_dir, "window_icon.png")
    
    # Save 512px version as the main app icon
    final_img.resize((512, 512), Image.Resampling.LANCZOS).save(assets_main, 'PNG')
    print(f"Generated: {assets_main}")
    
    # Save 64px version as window icon (for menu bar - smaller is better)
    final_img.resize((64, 64), Image.Resampling.LANCZOS).save(assets_window, 'PNG')
    print(f"Generated: {assets_window}")
    
    print("\n" + "=" * 50)
    print("Done! Icon extraction complete.")
    print(f"Check the extracted icon at: {final_path}")
    print(f"Original backup at: {original_backup}")
    print("\nTo rebuild the app with new icons:")
    print("  cd ui && flutter build macos")


if __name__ == "__main__":
    main()
