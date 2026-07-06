// Kiln: MobileNet image classification on the RK3576 NPU via librknnrt (RKNN).
//
// The CNN "control experiment" next to the RKLLM matmul path: same NPU, same
// out-of-tree vendor rknpu driver and the same MMU fix. If this classifies
// correctly, the driver's NPU-execution fix generalises from transformer matmul
// to convolution. Prints the top-5 ImageNet classes + NPU inference time.
//
// Usage: rknn_mobilenet <model.rknn> <image.jpg|png> [labels.txt]
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <chrono>

#include "rknn_api.h"
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

static std::vector<std::string> load_labels(const char *path)
{
	std::vector<std::string> v;
	if (!path)
		return v;
	FILE *f = fopen(path, "r");
	if (!f)
		return v;
	char line[512];
	while (fgets(line, sizeof(line), f)) {
		size_t n = strlen(line);
		while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
			line[--n] = 0;
		v.push_back(line);
	}
	fclose(f);
	return v;
}

static void *read_file(const char *path, size_t *out_size)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return nullptr;
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	void *buf = malloc(sz);
	if (buf && fread(buf, 1, sz, f) != (size_t)sz) {
		free(buf);
		buf = nullptr;
	}
	fclose(f);
	if (out_size)
		*out_size = sz;
	return buf;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s <model.rknn> <image.jpg|png> [labels.txt]\n", argv[0]);
		return 1;
	}

	size_t model_size = 0;
	void *model = read_file(argv[1], &model_size);
	if (!model) {
		fprintf(stderr, "cannot read model %s\n", argv[1]);
		return 1;
	}

	rknn_context ctx = 0;
	int ret = rknn_init(&ctx, model, model_size, 0, nullptr);
	free(model);
	if (ret < 0) {
		fprintf(stderr, "rknn_init failed: %d\n", ret);
		return 1;
	}

	rknn_input_output_num io_num;
	rknn_query(ctx, RKNN_QUERY_IN_OUT_NUM, &io_num, sizeof(io_num));

	rknn_tensor_attr in_attr;
	memset(&in_attr, 0, sizeof(in_attr));
	in_attr.index = 0;
	rknn_query(ctx, RKNN_QUERY_INPUT_ATTR, &in_attr, sizeof(in_attr));

	/* Query the output attr too -- the reference examples always do, and the
	 * runtime's want_float dequant path uses it. n_elems drives the class count. */
	rknn_tensor_attr out_attr;
	memset(&out_attr, 0, sizeof(out_attr));
	out_attr.index = 0;
	rknn_query(ctx, RKNN_QUERY_OUTPUT_ATTR, &out_attr, sizeof(out_attr));

	int req_h, req_w, req_c;
	if (in_attr.fmt == RKNN_TENSOR_NCHW) {      /* N C H W */
		req_c = in_attr.dims[1];
		req_h = in_attr.dims[2];
		req_w = in_attr.dims[3];
	} else {                                    /* N H W C */
		req_h = in_attr.dims[1];
		req_w = in_attr.dims[2];
		req_c = in_attr.dims[3];
	}
	printf("model: %u in / %u out, input %dx%dx%d fmt=%d n_dims=%u type=%d | out n_elems=%u dims=[%u %u %u %u]\n",
	       io_num.n_input, io_num.n_output, req_w, req_h, req_c,
	       in_attr.fmt, in_attr.n_dims, in_attr.type,
	       out_attr.n_elems, out_attr.dims[0], out_attr.dims[1],
	       out_attr.dims[2], out_attr.dims[3]);
	if (req_c != 3) {
		fprintf(stderr, "unexpected input channels %d (need 3)\n", req_c);
		rknn_destroy(ctx);
		return 1;
	}

	int iw, ih, ic;
	unsigned char *img = stbi_load(argv[2], &iw, &ih, &ic, 3);   /* force RGB */
	if (!img) {
		fprintf(stderr, "cannot decode image %s\n", argv[2]);
		rknn_destroy(ctx);
		return 1;
	}

	/* Nearest-neighbour resize to the model's input, uint8, in the layout the
	 * runtime advertises (RKNN image models present NHWC). rknn bakes the mean/std
	 * normalisation in, so raw 0-255 RGB is what to feed.
	 * NOTE: the runtime + model versions must match (like RKLLM's version-lock) --
	 * a MobileNet .rknn converted with toolkit 2.1.0 threw an out-of-range in
	 * rknn_inputs_set under librknnrt 2.3.0; a 2.3.0-converted ONNX model just works. */
	int use_nchw = (in_attr.fmt == RKNN_TENSOR_NCHW);
	std::vector<uint8_t> in(3 * req_h * req_w);
	for (int y = 0; y < req_h; y++)
		for (int x = 0; x < req_w; x++) {
			int sx = x * iw / req_w, sy = y * ih / req_h;
			for (int c = 0; c < 3; c++) {
				uint8_t v = img[(sy * iw + sx) * 3 + c];
				if (use_nchw)
					in[c * req_h * req_w + y * req_w + x] = v;
				else
					in[(y * req_w + x) * 3 + c] = v;
			}
		}
	stbi_image_free(img);

	rknn_input inputs[1];
	memset(inputs, 0, sizeof(inputs));
	inputs[0].index = 0;
	inputs[0].type = RKNN_TENSOR_UINT8;
	inputs[0].fmt = use_nchw ? RKNN_TENSOR_NCHW : RKNN_TENSOR_NHWC;
	inputs[0].size = in.size();
	inputs[0].buf = in.data();
	ret = rknn_inputs_set(ctx, 1, inputs);
	if (ret < 0) {
		fprintf(stderr, "rknn_inputs_set failed: %d\n", ret);
		rknn_destroy(ctx);
		return 1;
	}

	auto t0 = std::chrono::steady_clock::now();
	ret = rknn_run(ctx, nullptr);
	double ms = std::chrono::duration<double, std::milli>(
			    std::chrono::steady_clock::now() - t0).count();
	if (ret < 0) {
		fprintf(stderr, "rknn_run failed: %d\n", ret);
		rknn_destroy(ctx);
		return 1;
	}

	rknn_output outputs[1];
	memset(outputs, 0, sizeof(outputs));
	outputs[0].want_float = 1;
	ret = rknn_outputs_get(ctx, 1, outputs, nullptr);
	if (ret < 0) {
		fprintf(stderr, "rknn_outputs_get failed: %d\n", ret);
		rknn_destroy(ctx);
		return 1;
	}

	int n = out_attr.n_elems ? (int)out_attr.n_elems
				 : (int)(outputs[0].size / sizeof(float));
	float *scores = (float *)outputs[0].buf;
	std::vector<int> idx(n);
	for (int i = 0; i < n; i++)
		idx[i] = i;
	int topk = n < 5 ? n : 5;
	std::partial_sort(idx.begin(), idx.begin() + topk, idx.end(),
			  [&](int a, int b) { return scores[a] > scores[b]; });

	std::vector<std::string> labels = load_labels(argc > 3 ? argv[3] : nullptr);
	/* some ImageNet label files have a leading "background" class (1001 rows) */
	int off = ((int)labels.size() == n + 1) ? 1 : 0;

	printf("\ntop-%d of %d classes  (NPU inference %.1f ms):\n", topk, n, ms);
	for (int k = 0; k < topk; k++) {
		int i = idx[k];
		const char *name = (i + off < (int)labels.size()) ? labels[i + off].c_str() : "?";
		printf("  %d. [%4d] %-28s %.4f\n", k + 1, i, name, scores[i]);
	}
	printf("[bench] rknn inference: %.1f ms (%.1f fps)\n", ms, ms > 0 ? 1000.0 / ms : 0.0);

	rknn_outputs_release(ctx, 1, outputs);
	rknn_destroy(ctx);
	return 0;
}
