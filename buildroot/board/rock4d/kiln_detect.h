// SPDX-License-Identifier: Apache-2.0
// kiln_detect.h -- EXPERIMENTAL object-detection foundation for the RK3576 NPU via
// librknnrt (RKNN). YOLOv8/YOLO11 (anchor-free DFL), YOLOv5/v7 (anchor-based), YOLOX
// (anchor-free + objectness), and YOLO-RAW: a decoded pre-NMS single output
// [1,N,4+ncls] (Ultralytics nms=False, e.g. YOLO26/YOLOv10) -- the format that runs
// on the RK3576 NPU (pure conv; CPU does NMS). (An END2END [1,N,6] NMS-in-model
// export also has a decoder but CRASHES on the NPU -- the NMS ops aren't supported.)
//
//   *** EXPERIMENTAL -- the decoders are UNIT-TESTED on the host with synthetic
//       tensors, but NOT yet verified end-to-end against a real model on a board. ***
//
// What is verified (host unit tests, no NPU): the letterbox preprocessing + inverse
// box mapping, IoU, per-class NMS, box drawing, AND the three per-branch decoders
// (planted synthetic tensors -> expected boxes). What still needs on-board
// verification: that a real converted .rknn's OUTPUT LAYOUT matches what the decoders
// assume -- output ordering, NCHW dims, num-class inference, and which family it is.
// Detection is OFF by default (`[vision] task = classify`).
//
// Deliberately SEPARATE from kiln_vision.h (classification): the result type,
// preprocessing, and post-processing are fundamentally different, and keeping them
// apart leaves the working classifier completely untouched. The decode math lives in
// PURE STATIC functions (decode_*_branch) so it is testable without an NPU.
//
// Design mirrors airockchip/rknn_model_zoo (examples/yolov8|yolov5|yolox/cpp). It
// reads floats (want_float=1) for correctness+simplicity -- the model's sigmoids are
// baked into the airockchip export, so values arrive activated. The int8-gating speed
// optimization is left as a future step. Models are user-supplied; Kiln bundles none
// (Ultralytics YOLOv5/8/11 are AGPL-3.0; YOLOX is Apache-2.0 -- see VISION.md).
//
// The ONE translation unit needing stb's decoder must `#define STB_IMAGE_IMPLEMENTATION`
// before including this (kiln_vision.h says the same; the include is guarded so a TU
// pulling both headers compiles stb once).
#pragma once
#include "rknn_api.h"
#ifndef KILN_STB_INCLUDED
#define KILN_STB_INCLUDED
#include "stb_image.h"
#endif
#include "kiln_config.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <algorithm>
#include <chrono>

struct KilnBox { float x1, y1, x2, y2; };                    // pixels in the ORIGINAL image
struct KilnDetection { KilnBox box; int class_id; std::string label; float score; };
struct KilnLetterbox { float scale; int pad_x, pad_y; int in_w, in_h; };
enum KilnDetector { KILN_DET_AUTO = 0, KILN_DET_YOLOV8, KILN_DET_YOLOV5, KILN_DET_YOLOX,
                    KILN_DET_END2END, KILN_DET_YOLORAW };

class KilnDetect {
public:
    // ===================== pure helpers (host-unit-tested) =====================

    static KilnLetterbox make_letterbox(int iw, int ih, int mw, int mh) {
        float s = std::min((float)mw / iw, (float)mh / ih);
        int nw = (int)std::lround(iw * s), nh = (int)std::lround(ih * s);
        KilnLetterbox lb; lb.scale = s; lb.pad_x = (mw - nw) / 2; lb.pad_y = (mh - nh) / 2;
        lb.in_w = iw; lb.in_h = ih; return lb;
    }
    static KilnBox unletterbox(KilnBox b, const KilnLetterbox &lb) {
        KilnBox o;
        o.x1 = (b.x1 - lb.pad_x) / lb.scale; o.y1 = (b.y1 - lb.pad_y) / lb.scale;
        o.x2 = (b.x2 - lb.pad_x) / lb.scale; o.y2 = (b.y2 - lb.pad_y) / lb.scale;
        o.x1 = clampf(o.x1, 0, lb.in_w); o.x2 = clampf(o.x2, 0, lb.in_w);
        o.y1 = clampf(o.y1, 0, lb.in_h); o.y2 = clampf(o.y2, 0, lb.in_h);
        return o;
    }
    static float iou(const KilnBox &a, const KilnBox &b) {
        float ix1 = std::max(a.x1, b.x1), iy1 = std::max(a.y1, b.y1);
        float ix2 = std::min(a.x2, b.x2), iy2 = std::min(a.y2, b.y2);
        float iw = std::max(0.f, ix2 - ix1), ih = std::max(0.f, iy2 - iy1);
        float inter = iw * ih, ua = area(a) + area(b) - inter;
        return ua > 0 ? inter / ua : 0.f;
    }
    // Per-class NMS: within a class keep the top box, drop others overlapping it past
    // iou_thresh. Different classes never suppress each other (rknn_model_zoo convention).
    static void nms(std::vector<KilnDetection> &d, float iou_thresh) {
        std::sort(d.begin(), d.end(), [](const KilnDetection &p, const KilnDetection &q) { return p.score > q.score; });
        std::vector<char> dead(d.size(), 0);
        for (size_t i = 0; i < d.size(); i++) {
            if (dead[i]) continue;
            for (size_t j = i + 1; j < d.size(); j++)
                if (!dead[j] && d[j].class_id == d[i].class_id && iou(d[i].box, d[j].box) > iou_thresh) dead[j] = 1;
        }
        std::vector<KilnDetection> keep;
        for (size_t i = 0; i < d.size(); i++) if (!dead[i]) keep.push_back(d[i]);
        d.swap(keep);
    }

    // --- per-branch decoders (PURE: explicit tensors + dims; testable w/ no NPU) ---
    // All read NCHW float tensors (want_float=1). Boxes come out in MODEL (letterboxed)
    // pixel coords; the caller un-letterboxes. Grid is gh x gw, stride the model-in/grid.

    // YOLOv8 / YOLO11: box tensor [1, 4*dfl, gh, gw] + score tensor [1, ncls, gh, gw].
    // Anchor-free: no objectness; score = max class prob; box via DFL (softmax->distance).
    static void decode_v8_branch(const float *box, const float *score, int gh, int gw,
                                 int ncls, int dfl, int stride, float conf,
                                 const std::vector<std::string> &labels, std::vector<KilnDetection> &out) {
        int cell = gh * gw;
        for (int i = 0; i < gh; i++) for (int j = 0; j < gw; j++) {
            int idx = i * gw + j;
            int best = -1; float bestp = conf;
            for (int c = 0; c < ncls; c++) { float p = score[c * cell + idx]; if (p > bestp) { bestp = p; best = c; } }
            if (best < 0) continue;
            float dist[4];
            for (int b = 0; b < 4; b++) dist[b] = dfl_expect(box + (b * dfl) * cell + idx, dfl, cell);
            KilnDetection d;
            d.box.x1 = (-dist[0] + j + 0.5f) * stride; d.box.y1 = (-dist[1] + i + 0.5f) * stride;
            d.box.x2 = ( dist[2] + j + 0.5f) * stride; d.box.y2 = ( dist[3] + i + 0.5f) * stride;
            d.class_id = best; d.score = bestp; d.label = label_of(labels, best);
            out.push_back(d);
        }
    }
    // YOLOv5 / YOLOv7: one tensor [1, 3*(5+ncls), gh, gw] (3 anchors x [x,y,w,h,obj,cls..]).
    // anchor = 6 ints (3 wh pairs, pixels). score = obj * class_prob. Values pre-activated.
    static void decode_v5_branch(const float *data, int gh, int gw, int ncls, int stride,
                                 const int *anchor, float conf,
                                 const std::vector<std::string> &labels, std::vector<KilnDetection> &out) {
        int cell = gh * gw, per = 5 + ncls;
        for (int a = 0; a < 3; a++) {
            int base = a * per;
            for (int i = 0; i < gh; i++) for (int j = 0; j < gw; j++) {
                int idx = i * gw + j;
                float obj = data[(base + 4) * cell + idx];
                if (obj < conf) continue;
                int best = -1; float bestp = 0;
                for (int c = 0; c < ncls; c++) { float p = data[(base + 5 + c) * cell + idx]; if (p > bestp) { bestp = p; best = c; } }
                float sc = obj * bestp;
                if (best < 0 || sc < conf) continue;
                float bx = data[(base + 0) * cell + idx] * 2.f - 0.5f;
                float by = data[(base + 1) * cell + idx] * 2.f - 0.5f;
                float bw = data[(base + 2) * cell + idx] * 2.f; bw = bw * bw * anchor[a * 2];
                float bh = data[(base + 3) * cell + idx] * 2.f; bh = bh * bh * anchor[a * 2 + 1];
                float cx = (bx + j) * stride, cy = (by + i) * stride;
                out.push_back({{cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2}, best, label_of(labels, best), sc});
            }
        }
    }
    // YOLOX: one tensor [1, 5+ncls, gh, gw] ([x,y,w,h,obj,cls..]). Anchor-free w/ obj;
    // xy = grid+stride, wh = exp()*stride. score = obj * class_prob.
    static void decode_yolox_branch(const float *data, int gh, int gw, int ncls, int stride,
                                    float conf, const std::vector<std::string> &labels, std::vector<KilnDetection> &out) {
        int cell = gh * gw;
        for (int i = 0; i < gh; i++) for (int j = 0; j < gw; j++) {
            int idx = i * gw + j;
            float obj = data[4 * cell + idx];
            if (obj < conf) continue;
            int best = -1; float bestp = 0;
            for (int c = 0; c < ncls; c++) { float p = data[(5 + c) * cell + idx]; if (p > bestp) { bestp = p; best = c; } }
            float sc = obj * bestp;
            if (best < 0 || sc < conf) continue;
            float cx = (data[0 * cell + idx] + j) * stride, cy = (data[1 * cell + idx] + i) * stride;
            float w = std::exp(data[2 * cell + idx]) * stride, h = std::exp(data[3 * cell + idx]) * stride;
            out.push_back({{cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2}, best, label_of(labels, best), sc});
        }
    }

    // End2end / NMS-in-model YOLO. ONE output [1, N, 6]: N rows of
    // [x1, y1, x2, y2, score, class_id] in MODEL coords, already NMS'd. Just threshold
    // + un-letterbox. NOTE: the in-model NMS ops (TopK/GatherElements) do NOT run on
    // the RK3576 NPU -- an end2end .rknn CRASHES librknnrt. Export with NMS OFF and use
    // KILN_DET_YOLORAW instead. This decoder is kept for a runtime that ever supports it.
    static void decode_end2end_branch(const float *data, int num_rows, float conf,
                                      const std::vector<std::string> &labels, std::vector<KilnDetection> &out) {
        for (int i = 0; i < num_rows; i++) {
            const float *r = data + i * 6;
            float score = r[4];
            if (score < conf) continue;
            int cls = (int)(r[5] + 0.5f);
            out.push_back({{r[0], r[1], r[2], r[3]}, cls, label_of(labels, cls), score});
        }
    }

    // Decoded-but-NOT-NMS'd single output [1, N, 4+ncls]: per anchor
    // [x1, y1, x2, y2, cls0..clsN] with the box already xyxy in MODEL coords. This is
    // the Ultralytics `nms=False` export (or an end2end graph cut before the NMS tail)
    // and is the format that runs cleanly on the RK3576 NPU (pure conv). Threshold by
    // the max class; the caller un-letterboxes and runs CPU NMS.
    static void decode_yoloraw_branch(const float *data, int num_rows, int ncols, float conf,
                                      const std::vector<std::string> &labels, std::vector<KilnDetection> &out) {
        int nc = ncols - 4;
        for (int i = 0; i < num_rows; i++) {
            const float *r = data + i * ncols;
            int best = -1; float bestp = conf;
            for (int c = 0; c < nc; c++) { float p = r[4 + c]; if (p > bestp) { bestp = p; best = c; } }
            if (best < 0) continue;
            out.push_back({{r[0], r[1], r[2], r[3]}, best, label_of(labels, best), bestp});
        }
    }

    // Draw box outlines (per-class colour) into an RGB buffer (w*h*3). Labels are in
    // the printed/JSON output; text overlay would need a bundled font, so boxes only.
    static void draw_boxes(unsigned char *rgb, int w, int h, const std::vector<KilnDetection> &dets, int thick = 3) {
        for (const auto &d : dets) {
            unsigned char r, g, b; class_color(d.class_id, r, g, b);
            draw_rect(rgb, w, h, (int)d.box.x1, (int)d.box.y1, (int)d.box.x2, (int)d.box.y2, r, g, b, thick);
        }
    }

    // ===================== NPU path =====================
    int init(const KilnConfig &cfg) {
        cfg_ = cfg;
        family_ = parse_family(cfg.vision_detector);
        size_t sz = 0;
        void *model = read_file(cfg.vision_model.c_str(), &sz);
        if (!model) { snprintf(err_, sizeof(err_), "cannot read model %s", cfg.vision_model.c_str()); return -1; }

        uint32_t flag = 0;
        if      (cfg.vision_priority == "medium") flag = RKNN_FLAG_PRIOR_MEDIUM;
        else if (cfg.vision_priority == "low")    flag = RKNN_FLAG_PRIOR_LOW;
        else                                      flag = RKNN_FLAG_PRIOR_HIGH;
        int ret = rknn_init(&ctx_, model, sz, flag, nullptr);
        free(model);
        if (ret < 0) { snprintf(err_, sizeof(err_), "rknn_init failed: %d", ret); return ret; }

        rknn_core_mask cm = RKNN_NPU_CORE_AUTO;
        if      (cfg.vision_core_mask == "0")   cm = RKNN_NPU_CORE_0;
        else if (cfg.vision_core_mask == "1")   cm = RKNN_NPU_CORE_1;
        else if (cfg.vision_core_mask == "0_1") cm = RKNN_NPU_CORE_0_1;
        rknn_set_core_mask(ctx_, cm);

        rknn_query(ctx_, RKNN_QUERY_IN_OUT_NUM, &io_, sizeof(io_));
        memset(&in_, 0, sizeof(in_)); in_.index = 0;
        rknn_query(ctx_, RKNN_QUERY_INPUT_ATTR, &in_, sizeof(in_));
        if (in_.fmt == RKNN_TENSOR_NCHW) { c_ = in_.dims[1]; h_ = in_.dims[2]; w_ = in_.dims[3]; }
        else                             { h_ = in_.dims[1]; w_ = in_.dims[2]; c_ = in_.dims[3]; }
        nchw_ = (in_.fmt == RKNN_TENSOR_NCHW);
        if (c_ != 3) { snprintf(err_, sizeof(err_), "input channels %d (need 3)", c_); return -1; }

        // Detectors have 1 output ([1,N,6] end2end/NMS-in-model) or several (grid heads).
        // A classifier (1 output, not [.,.,6]) simply decodes to nothing, no crash.
        if (io_.n_output < 1) { snprintf(err_, sizeof(err_), "model has no outputs"); return -1; }
        out_attrs_.resize(io_.n_output);
        for (uint32_t i = 0; i < io_.n_output; i++) {
            memset(&out_attrs_[i], 0, sizeof(rknn_tensor_attr));
            out_attrs_[i].index = i;
            rknn_query(ctx_, RKNN_QUERY_OUTPUT_ATTR, &out_attrs_[i], sizeof(rknn_tensor_attr));
        }
        labels_ = load_labels(cfg.vision_labels.c_str());
        return 0;
    }

    std::vector<KilnDetection> detect_rgb(const unsigned char *rgb, int iw, int ih,
                                          float conf, float nms_iou, double *ms, std::string *err) {
        std::vector<KilnDetection> out;
        KilnLetterbox lb = make_letterbox(iw, ih, w_, h_);
        std::vector<uint8_t> buf(3 * h_ * w_, 114);
        int nw = (int)std::lround(iw * lb.scale), nh = (int)std::lround(ih * lb.scale);
        for (int y = 0; y < nh; y++) {
            int sy = std::min(ih - 1, (int)(y / lb.scale));
            for (int x = 0; x < nw; x++) {
                int sx = std::min(iw - 1, (int)(x / lb.scale));
                int dy = y + lb.pad_y, dx = x + lb.pad_x;
                for (int cc = 0; cc < 3; cc++) {
                    uint8_t v = rgb[(sy * iw + sx) * 3 + cc];
                    if (nchw_) buf[cc * h_ * w_ + dy * w_ + dx] = v;
                    else       buf[(dy * w_ + dx) * 3 + cc] = v;
                }
            }
        }
        rknn_input in; memset(&in, 0, sizeof(in));
        in.index = 0; in.type = RKNN_TENSOR_UINT8;
        in.fmt = nchw_ ? RKNN_TENSOR_NCHW : RKNN_TENSOR_NHWC;
        in.size = buf.size(); in.buf = buf.data();
        if (rknn_inputs_set(ctx_, 1, &in) < 0) { if (err) *err = "rknn_inputs_set failed"; return out; }

        auto t0 = std::chrono::steady_clock::now();
        int ret = rknn_run(ctx_, nullptr);
        double t = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        if (ms) *ms = t;
        if (ret < 0) { if (err) *err = "rknn_run failed"; return out; }

        std::vector<rknn_output> outs(io_.n_output);
        memset(outs.data(), 0, outs.size() * sizeof(rknn_output));
        for (uint32_t i = 0; i < io_.n_output; i++) outs[i].want_float = 1;
        if (rknn_outputs_get(ctx_, io_.n_output, outs.data(), nullptr) < 0) { if (err) *err = "rknn_outputs_get failed"; return out; }

        decode(outs, conf, out);
        rknn_outputs_release(ctx_, io_.n_output, outs.data());

        for (auto &d : out) d.box = unletterbox(d.box, lb);
        if (family() != KILN_DET_END2END) nms(out, nms_iou);   // end2end already NMS'd
        return out;
    }
    std::vector<KilnDetection> detect_encoded(const unsigned char *data, int len,
                                              float conf, float nms_iou, double *ms, std::string *err) {
        int iw, ih, ic;
        unsigned char *img = stbi_load_from_memory(data, len, &iw, &ih, &ic, 3);
        if (!img) { if (err) *err = "cannot decode image"; return {}; }
        auto r = detect_rgb(img, iw, ih, conf, nms_iou, ms, err);
        stbi_image_free(img); return r;
    }
    std::vector<KilnDetection> detect_file(const std::string &path, float conf, float nms_iou,
                                           double *ms, std::string *err) {
        int iw, ih, ic;
        unsigned char *img = stbi_load(path.c_str(), &iw, &ih, &ic, 3);
        if (!img) { if (err) *err = "cannot decode image " + path; return {}; }
        auto r = detect_rgb(img, iw, ih, conf, nms_iou, ms, err);
        stbi_image_free(img); return r;
    }

    bool ok() const { return ctx_ != 0; }
    const char *error() const { return err_; }
    int in_w() const { return w_; } int in_h() const { return h_; }
    KilnDetector family() const { return family_ == KILN_DET_AUTO ? auto_family() : family_; }
    const char *family_name() const { return det_name(family()); }
    ~KilnDetect() { if (ctx_) rknn_destroy(ctx_); }

    static KilnDetector parse_family(const std::string &s) {
        if (s == "yolov8" || s == "yolo11" || s == "yolov11")   return KILN_DET_YOLOV8;
        if (s == "yolov5" || s == "yolov7")                     return KILN_DET_YOLOV5;
        if (s == "yolox")                                       return KILN_DET_YOLOX;
        if (s == "end2end")                                     return KILN_DET_END2END;
        if (s == "yoloraw" || s == "raw" || s == "yolo26" || s == "yolov10") return KILN_DET_YOLORAW;
        return KILN_DET_AUTO;
    }
    static const char *det_name(KilnDetector f) {
        switch (f) { case KILN_DET_YOLOV8: return "yolov8/11"; case KILN_DET_YOLOV5: return "yolov5/7";
                     case KILN_DET_YOLOX: return "yolox"; case KILN_DET_END2END: return "end2end";
                     case KILN_DET_YOLORAW: return "yolo-raw (xyxy)"; default: return "auto"; }
    }

private:
    static float area(const KilnBox &b) { return std::max(0.f, b.x2 - b.x1) * std::max(0.f, b.y2 - b.y1); }
    static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
    static std::string label_of(const std::vector<std::string> &L, int i) {
        return (i >= 0 && i < (int)L.size()) ? L[i] : ("class " + std::to_string(i));
    }
    // DFL: softmax over `dfl` bins (stride `cell` in memory) -> expected value.
    static float dfl_expect(const float *p, int dfl, int cell) {
        float tmp[32]; int n = dfl > 32 ? 32 : dfl; float sum = 0, acc = 0;
        for (int k = 0; k < n; k++) { tmp[k] = std::exp(p[k * cell]); sum += tmp[k]; }
        for (int k = 0; k < n; k++) acc += (tmp[k] / sum) * k;
        return acc;
    }
    static void dims_nchw(const rknn_tensor_attr &a, int &gh, int &gw, int &ch) {
        if (a.n_dims == 4) { ch = a.dims[1]; gh = a.dims[2]; gw = a.dims[3]; } else { ch = gh = gw = 0; }
    }

    // Pick a family from the output shapes when task=detect but detector=auto.
    KilnDetector auto_family() const {
        if (io_.n_output == 1) {                                            // one output
            const rknn_tensor_attr &a = out_attrs_[0];
            int last = a.n_dims >= 1 ? (int)a.dims[a.n_dims - 1] : 0;
            if (a.n_dims >= 2 && last == 6) return KILN_DET_END2END;        // [1,N,6] NMS-in-model
            if (a.n_dims >= 2 && last  > 6) return KILN_DET_YOLORAW;        // [1,N,4+ncls] decoded, pre-NMS
        }
        if (io_.n_output == 6 || io_.n_output == 9) return KILN_DET_YOLOV8;
        if (io_.n_output == 3) {
            int gh, gw, ch; dims_nchw(out_attrs_[0], gh, gw, ch);
            if (ch % 3 == 0 && (ch / 3 - 5) > 0) return KILN_DET_YOLOV5;   // 3*(5+ncls)
            return KILN_DET_YOLOX;                                          // 5+ncls
        }
        return KILN_DET_YOLOV8;
    }

    void decode(const std::vector<rknn_output> &outs, float conf, std::vector<KilnDetection> &out) {
        KilnDetector fam = family_ == KILN_DET_AUTO ? auto_family() : family_;
        if (fam == KILN_DET_END2END || fam == KILN_DET_YOLORAW) {
            const rknn_tensor_attr &a = out_attrs_[0];
            int rows = a.n_dims >= 2 ? (int)a.dims[a.n_dims - 2] : 0;       // [1,N,C] -> N
            int cols = a.n_dims >= 1 ? (int)a.dims[a.n_dims - 1] : 0;       // -> C
            if (rows <= 0) return;
            if (fam == KILN_DET_END2END && cols == 6) decode_end2end_branch((const float *)outs[0].buf, rows, conf, labels_, out);
            else if (fam == KILN_DET_YOLORAW && cols > 4) decode_yoloraw_branch((const float *)outs[0].buf, rows, cols, conf, labels_, out);
            return;
        }
        if (fam == KILN_DET_YOLOV8) {
            int opb = (int)io_.n_output / 3; if (opb < 2) return;
            for (int s = 0; s < 3; s++) {
                int bi = s * opb, si = bi + 1; if (si >= (int)io_.n_output) break;
                int gh, gw, bch, sgh, sgw, ncls;
                dims_nchw(out_attrs_[bi], gh, gw, bch);
                dims_nchw(out_attrs_[si], sgh, sgw, ncls);
                if (gh <= 0 || gw <= 0 || bch % 4 != 0) continue;
                decode_v8_branch((const float *)outs[bi].buf, (const float *)outs[si].buf,
                                 gh, gw, ncls, bch / 4, h_ / gh, conf, labels_, out);
            }
        } else if (fam == KILN_DET_YOLOV5) {
            for (int s = 0; s < 3 && s < (int)io_.n_output; s++) {
                int gh, gw, ch; dims_nchw(out_attrs_[s], gh, gw, ch);
                if (gh <= 0 || ch % 3 != 0) continue;
                int ncls = ch / 3 - 5; if (ncls <= 0) continue;
                int stride = h_ / gh;
                decode_v5_branch((const float *)outs[s].buf, gh, gw, ncls, stride,
                                 v5_anchor(stride, s), conf, labels_, out);
            }
        } else { // YOLOX
            for (int s = 0; s < 3 && s < (int)io_.n_output; s++) {
                int gh, gw, ch; dims_nchw(out_attrs_[s], gh, gw, ch);
                if (gh <= 0 || ch <= 5) continue;
                decode_yolox_branch((const float *)outs[s].buf, gh, gw, ch - 5, h_ / gh, conf, labels_, out);
            }
        }
    }
    // COCO default v5 anchors by stride (8/16/32); fall back to branch index.
    static const int *v5_anchor(int stride, int branch) {
        static const int A[3][6] = { {10,13,16,30,33,23}, {30,61,62,45,59,119}, {116,90,156,198,373,326} };
        int row = stride == 8 ? 0 : stride == 16 ? 1 : stride == 32 ? 2 : (branch % 3);
        return A[row];
    }

    static void class_color(int c, unsigned char &r, unsigned char &g, unsigned char &b) {
        // deterministic spread of hues so different classes get different colours
        unsigned h = (unsigned)(c * 47 + 13);
        r = 64 + (h * 41) % 192; g = 64 + (h * 97) % 192; b = 64 + (h * 71) % 192;
    }
    static void draw_rect(unsigned char *rgb, int w, int h, int x1, int y1, int x2, int y2,
                          unsigned char r, unsigned char g, unsigned char b, int thick) {
        x1 = std::max(0, std::min(w - 1, x1)); x2 = std::max(0, std::min(w - 1, x2));
        y1 = std::max(0, std::min(h - 1, y1)); y2 = std::max(0, std::min(h - 1, y2));
        for (int t = 0; t < thick; t++) {
            for (int x = x1; x <= x2; x++) { px(rgb, w, h, x, y1 + t, r, g, b); px(rgb, w, h, x, y2 - t, r, g, b); }
            for (int y = y1; y <= y2; y++) { px(rgb, w, h, x1 + t, y, r, g, b); px(rgb, w, h, x2 - t, y, r, g, b); }
        }
    }
    static void px(unsigned char *rgb, int w, int h, int x, int y, unsigned char r, unsigned char g, unsigned char b) {
        if (x < 0 || y < 0 || x >= w || y >= h) return;
        unsigned char *p = rgb + (y * w + x) * 3; p[0] = r; p[1] = g; p[2] = b;
    }

    static void *read_file(const char *path, size_t *out) {
        FILE *f = fopen(path, "rb"); if (!f) return nullptr;
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        void *b = malloc(sz);
        if (b && fread(b, 1, sz, f) != (size_t)sz) { free(b); b = nullptr; }
        fclose(f); if (out) *out = sz; return b;
    }
    static std::vector<std::string> load_labels(const char *path) {
        std::vector<std::string> v;
        if (!path || !*path) return v;
        FILE *f = fopen(path, "r"); if (!f) return v;
        char line[512];
        while (fgets(line, sizeof(line), f)) {
            size_t n = strlen(line);
            while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
            v.push_back(line);
        }
        fclose(f); return v;
    }

    rknn_context ctx_ = 0;
    rknn_input_output_num io_{};
    rknn_tensor_attr in_{};
    std::vector<rknn_tensor_attr> out_attrs_;
    int w_ = 0, h_ = 0, c_ = 0; bool nchw_ = false;
    KilnDetector family_ = KILN_DET_AUTO;
    std::vector<std::string> labels_;
    KilnConfig cfg_;
    char err_[256] = {0};
};
