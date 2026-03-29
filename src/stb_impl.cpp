// stb implementations — isolated translation unit
// Compiles once, cached as .o, never recompiles unless you change vendor headers
#define STB_TRUETYPE_IMPLEMENTATION
#include "vendor/stb_truetype.h"

#define STB_IMAGE_IMPLEMENTATION
#include "vendor/stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "vendor/stb_image_write.h"
