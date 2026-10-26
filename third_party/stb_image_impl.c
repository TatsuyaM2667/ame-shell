// stb_image の実装単位。PNG/JPEG の壁紙・アルバムアート読み込みに使う(C、パブリックドメイン)。
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO_FAILURE_STRINGS
#include "stb_image.h"
