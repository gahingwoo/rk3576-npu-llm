// Kiln: image classification on the RK3576 NPU via librknnrt (RKNN). The CNN
// control experiment next to kiln-chat's RKLLM matmul path.
//
// Now config-driven (kiln_vision.h + kiln_config.h): model / labels / top-N /
// NPU core mask / priority come from /etc/kiln/config.ini. The RKNN call
// sequence is unchanged -- it just lives in kiln_vision.h so kiln-serve reuses
// it too.
//
// Usage:
//   rknn_mobilenet <image.jpg>                     # model/labels from config
//   rknn_mobilenet <model.rknn> <image> [labels]   # explicit override (old form)
#define STB_IMAGE_IMPLEMENTATION
#include "kiln_vision.h"
#include "kiln_detect.h"   // task = detect (EXPERIMENTAL YOLO); STB impl is this TU's
#include "kiln_config.h"
// optional: save an annotated image with detection boxes drawn (kiln-vision img out.jpg)
#if __has_include("stb_image_write.h")
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#define KILN_HAVE_STB_WRITE 1
#endif
#include <cstdio>
#include <string>

static bool ends_with(const std::string &s, const char *suf) {
    std::string t = suf;
    return s.size() >= t.size() && s.compare(s.size() - t.size(), t.size(), t) == 0;
}

// EXPERIMENTAL object-detection path (config [vision] task = detect). Kept separate
// from the classifier; prints an honest "unverified" banner -- Kiln does not claim
// working detection (see kiln_detect.h / VISION.md).
static int run_detect(KilnConfig &cfg, const std::string &image, const std::string &save) {
    fprintf(stderr,
        "kiln-vision: task=detect is EXPERIMENTAL (YOLO, UNVERIFIED on hardware) --\n"
        "             boxes may be wrong; see VISION.md. Use [vision] task=classify to disable.\n");
    KilnDetect d;
    if (d.init(cfg) != 0) { fprintf(stderr, "kiln-vision: %s\n", d.error()); return 1; }
    double ms = 0; std::string err;
    auto dets = d.detect_file(image, cfg.vision_conf, cfg.vision_nms_iou, &ms, &err);
    if (dets.empty() && !err.empty()) { fprintf(stderr, "kiln-vision: %s\n", err.c_str()); return 1; }
    printf("\n%zu detection(s)  (%s, NPU inference %.1f ms, conf>=%.2f, nms=%.2f):\n",
           dets.size(), d.family_name(), ms, cfg.vision_conf, cfg.vision_nms_iou);
    for (const auto &o : dets)
        printf("  [%3d] %-22s %.2f   box (%.0f,%.0f)-(%.0f,%.0f)\n",
               o.class_id, o.label.c_str(), o.score, o.box.x1, o.box.y1, o.box.x2, o.box.y2);
    printf("[bench] rknn inference: %.1f ms (%.1f fps)\n", ms, ms > 0 ? 1000.0 / ms : 0.0);

    if (!save.empty()) {
#ifdef KILN_HAVE_STB_WRITE
        int iw, ih, ic;
        unsigned char *img = stbi_load(image.c_str(), &iw, &ih, &ic, 3);
        if (img) {
            KilnDetect::draw_boxes(img, iw, ih, dets);
            if (stbi_write_jpg(save.c_str(), iw, ih, 3, img, 90)) printf("  saved annotated image -> %s\n", save.c_str());
            else fprintf(stderr, "kiln-vision: couldn't write %s\n", save.c_str());
            stbi_image_free(img);
        }
#else
        fprintf(stderr, "kiln-vision: saving an annotated image needs stb_image_write.h at build time; skipped.\n");
#endif
    }
    return 0;
}

int main(int argc, char **argv) {
    KilnConfig cfg;
    kiln::load(cfg);

    std::string image;
    // old form: <model.rknn> <image> [labels] overrides config
    if (argc >= 3 && ends_with(argv[1], ".rknn")) {
        cfg.vision_model = argv[1];
        image = argv[2];
        if (argc > 3) cfg.vision_labels = argv[3];
    } else {
        image = argc > 1 ? argv[1] : "/opt/models/test.jpg";
    }

    // dispatch on the vision task; detect is the EXPERIMENTAL YOLO path. An extra
    // image-path arg (kiln-vision img.jpg out.jpg) saves the annotated result.
    if (cfg.vision_task == "detect") {
        std::string save;
        for (int k = 1; k < argc; k++) {
            std::string s = argv[k];
            if (s != image && (ends_with(s, ".jpg") || ends_with(s, ".jpeg") || ends_with(s, ".png") || ends_with(s, ".bmp"))) save = s;
        }
        return run_detect(cfg, image, save);
    }

    KilnVision v;
    if (v.init(cfg) != 0) { fprintf(stderr, "kiln-vision: %s\n", v.error()); return 1; }

    double ms = 0; std::string err;
    auto res = v.classify_file(image, cfg.vision_top_n, &ms, &err);
    if (res.empty() && !err.empty()) { fprintf(stderr, "kiln-vision: %s\n", err.c_str()); return 1; }

    printf("\ntop-%d  (NPU inference %.1f ms):\n", (int)res.size(), ms);
    for (size_t k = 0; k < res.size(); k++)
        printf("  %zu. [%4d] %-28s %.4f\n", k + 1, res[k].index, res[k].label.c_str(), res[k].score);
    printf("[bench] rknn inference: %.1f ms (%.1f fps)\n", ms, ms > 0 ? 1000.0 / ms : 0.0);
    return 0;
}
