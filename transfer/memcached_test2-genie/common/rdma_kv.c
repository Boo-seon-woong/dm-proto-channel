/* rdma_kv transport impl — see rdma_kv.h. Event-driven RC one-sided. */
#define _GNU_SOURCE
#include "rdma_kv.h"
#include "kv_layout.h"

uint32_t KV_SLOT = 1024;   /* runtime slot size; compute/memnode set it via -V (see kv_layout.h) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <poll.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

struct conn_info {           /* exchanged over TCP */
	uint64_t vaddr;
	uint32_t rkey;
	uint32_t qpn;
	uint32_t psn;
	uint16_t lid;
	uint16_t pad;
} __attribute__((packed));

static uint64_t now_ns(void) {
	struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
}
static int write_full(int fd, const void *b, size_t n) {
	const char *p = b; while (n) { ssize_t k = write(fd, p, n); if (k <= 0) return -1; p += k; n -= k; } return 0;
}
static int read_full(int fd, void *b, size_t n) {
	char *p = b; while (n) { ssize_t k = read(fd, p, n); if (k <= 0) return -1; p += k; n -= k; } return 0;
}

int rdma_kv_open(struct rdma_conn *c, const char *dev, int ib_port,
		 void *buf, size_t buf_size) {
	c->rem_vaddr = 0; c->rem_rkey = 0;
	c->buf = buf; c->buf_size = buf_size; c->poll_ms = 5000; c->e2e = 0;
	struct ibv_device **list = ibv_get_device_list(NULL);
	if (!list) { perror("ibv_get_device_list"); return -1; }
	struct ibv_device *d = NULL;
	for (int i = 0; list[i]; i++)
		if (!dev || !strcmp(ibv_get_device_name(list[i]), dev)) { d = list[i]; break; }
	if (!d) { fprintf(stderr, "device %s not found\n", dev ? dev : "(any)"); return -1; }
	c->ctx = ibv_open_device(d);
	ibv_free_device_list(list);
	if (!c->ctx) { fprintf(stderr, "ibv_open_device(%s) failed\n", dev); return -1; }
	c->pd = ibv_alloc_pd(c->ctx);
	c->chan = ibv_create_comp_channel(c->ctx);
	if (!c->pd || !c->chan) { fprintf(stderr, "pd/chan alloc failed\n"); return -1; }
	c->cq = ibv_create_cq(c->ctx, 256, NULL, c->chan, 0);
	if (!c->cq) { fprintf(stderr, "create_cq failed\n"); return -1; }
	/* SEV-SNP: ibv_reg_mr intermittently returns EIO (bounce-MR async-cleanup
	 * race); it succeeds on retry. Non-TEE nodes take the first try. */
	for (int t = 0; t < 30; t++) {
		c->mr = ibv_reg_mr(c->pd, buf, buf_size,
				   IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE);
		if (c->mr) break;
		if (errno != EIO) break;
		struct timespec ts = { .tv_sec = 0, .tv_nsec = 200 * 1000 * 1000 };
		nanosleep(&ts, NULL);
	}
	if (!c->mr) { fprintf(stderr, "ibv_reg_mr(%zu) failed: %s\n", buf_size, strerror(errno)); return -1; }
	struct ibv_qp_init_attr qa = {
		.send_cq = c->cq, .recv_cq = c->cq, .qp_type = IBV_QPT_RC,
		.cap = { .max_send_wr = 64, .max_recv_wr = 1, .max_send_sge = 1, .max_recv_sge = 1 },
	};
	c->qp = ibv_create_qp(c->pd, &qa);
	if (!c->qp) { fprintf(stderr, "create_qp failed\n"); return -1; }
	struct ibv_qp_attr a = { .qp_state = IBV_QPS_INIT, .pkey_index = 0, .port_num = (uint8_t)ib_port,
		.qp_access_flags = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE };
	if (ibv_modify_qp(c->qp, &a, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS)) {
		perror("modify INIT"); return -1;
	}
	return 0;
}

static int to_rtr_rts(struct rdma_conn *c, int ib_port, const struct conn_info *rem, uint32_t my_psn) {
	struct ibv_qp_attr a = {
		.qp_state = IBV_QPS_RTR, .path_mtu = IBV_MTU_4096,
		.dest_qp_num = rem->qpn, .rq_psn = rem->psn, .max_dest_rd_atomic = 16, .min_rnr_timer = 12,
		.ah_attr = { .is_global = 0, .dlid = rem->lid, .sl = 0, .src_path_bits = 0, .port_num = (uint8_t)ib_port },
	};
	if (ibv_modify_qp(c->qp, &a, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN |
			  IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER)) {
		perror("modify RTR"); return -1;
	}
	struct ibv_qp_attr b = { .qp_state = IBV_QPS_RTS, .timeout = 14, .retry_cnt = 7, .rnr_retry = 7,
		.sq_psn = my_psn, .max_rd_atomic = 16 };
	if (ibv_modify_qp(c->qp, &b, IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
			  IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC)) {
		perror("modify RTS"); return -1;
	}
	c->rem_vaddr = rem->vaddr; c->rem_rkey = rem->rkey;
	return 0;
}

static int fill_local(struct rdma_conn *c, int ib_port, struct conn_info *me, uint32_t psn) {
	struct ibv_port_attr pa;
	if (ibv_query_port(c->ctx, (uint8_t)ib_port, &pa)) { perror("query_port"); return -1; }
	me->lid = pa.lid; me->qpn = c->qp->qp_num; me->psn = psn;
	me->vaddr = (uint64_t)(uintptr_t)c->buf; me->rkey = c->mr->rkey; me->pad = 0;
	return 0;
}

int rdma_kv_serve(struct rdma_conn *c, int ib_port, int tcp_port) {
	int ls = socket(AF_INET, SOCK_STREAM, 0); int one = 1;
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr.s_addr = INADDR_ANY, .sin_port = htons(tcp_port) };
	if (bind(ls, (void *)&sa, sizeof(sa)) || listen(ls, 4)) { perror("bind/listen"); return -1; }
	uint32_t psn = 0x1234; struct conn_info me, peer;
	if (fill_local(c, ib_port, &me, psn)) { close(ls); return -1; }
	/* Loop the TCP accept+exchange: skip stray/garbage connections (e.g. a probe)
	 * so one bad connect can't kill the memory node. The QP stays in INIT until a
	 * valid peer completes the exchange. */
	for (;;) {
		int s = accept(ls, NULL, NULL);
		if (s < 0) { if (errno == EINTR) continue; perror("accept"); close(ls); return -1; }
		if (read_full(s, &peer, sizeof(peer)) || write_full(s, &me, sizeof(me))) {
			fprintf(stderr, "[memnode] skipping bad/short connect\n"); close(s); continue;
		}
		c->peer_fd = s;   /* keep open: liveness channel (EOF = compute gone) */
		break;
	}
	close(ls);
	return to_rtr_rts(c, ib_port, &peer, psn);
}

int rdma_kv_connect(struct rdma_conn *c, int ib_port, const char *ip, int tcp_port) {
	int s = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(tcp_port) };
	inet_pton(AF_INET, ip, &sa.sin_addr);
	if (connect(s, (void *)&sa, sizeof(sa))) { perror("connect"); close(s); return -1; }
	uint32_t psn = 0x5678; struct conn_info me, peer;
	if (fill_local(c, ib_port, &me, psn)) return -1;
	if (write_full(s, &me, sizeof(me)) || read_full(s, &peer, sizeof(peer))) { close(s); return -1; }
	c->peer_fd = s;   /* keep open until this process exits (memnode watches for EOF) */
	return to_rtr_rts(c, ib_port, &peer, psn);
}

/* ---- TCP-backend ablation: same fixed-slot store over a plain TCP req/resp socket ---- */
struct kv_req { uint8_t op; uint64_t off; uint32_t len; } __attribute__((packed));  /* op: 'R'/'W' */

int rdma_kv_connect_tcp(struct rdma_conn *c, const char *ip, int tcp_port, void *buf, size_t buf_size) {
	memset(c, 0, sizeof(*c));
	c->buf = buf; c->buf_size = buf_size; c->backend = 1;
	int s = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(tcp_port) };
	inet_pton(AF_INET, ip, &sa.sin_addr);
	if (connect(s, (void *)&sa, sizeof(sa))) { perror("tcp backend connect"); close(s); return -1; }
	int one = 1; setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
	c->peer_fd = s;
	return 0;
}

/* Memory node side: one accepted compute node drives read/write requests until it detaches. */
int rdma_kv_serve_tcp(int tcp_port, void *store, size_t store_size) {
	int ls = socket(AF_INET, SOCK_STREAM, 0); int one = 1;
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr.s_addr = INADDR_ANY, .sin_port = htons(tcp_port) };
	if (bind(ls, (void *)&sa, sizeof(sa)) || listen(ls, 4)) { perror("bind/listen"); return -1; }
	int s = accept(ls, NULL, NULL); close(ls);
	if (s < 0) { perror("accept"); return -1; }
	setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
	for (;;) {
		struct kv_req r;
		if (read_full(s, &r, sizeof(r))) break;          /* compute detached (EOF) -> return for respawn */
		if (r.off + r.len > store_size) break;           /* bounds guard */
		char *slot = (char *)store + r.off;
		if (r.op == 'W') { if (read_full(s, slot, r.len)) break; char ack = 1; if (write_full(s, &ack, 1)) break; }
		else             { if (write_full(s, slot, r.len)) break; }
	}
	close(s);
	return 0;
}

static int tcp_do(struct rdma_conn *c, uint8_t op, size_t loff, size_t roff, uint32_t len) {
	struct kv_req r = { .op = op, .off = roff, .len = len };
	if (write_full(c->peer_fd, &r, sizeof(r))) return -1;
	if (op == 'W') {
		if (write_full(c->peer_fd, (char *)c->buf + loff, len)) return -1;
		char ack; if (read_full(c->peer_fd, &ack, 1)) return -1;
	} else {
		if (read_full(c->peer_fd, (char *)c->buf + loff, len)) return -1;
	}
	return 0;
}

/* one-sided op with event-driven completion (SEV-safe). */
static int one_sided(struct rdma_conn *c, int opcode, size_t loff, size_t roff, uint32_t len) {
	struct ibv_mr *opmr = NULL;
	uint32_t lkey = c->mr->lkey;
	if (c->e2e) {
		/* End-to-end-to-private: register the op's local slice fresh. reg dma_maps
		 * (private->bounce, so a WRITE source is current) and dereg dma_unmaps
		 * (bounce->private, so a READ actually lands in encrypted guest memory) — the data
		 * completes its round trip to/from private memory every op instead of stalling in the
		 * shared bounce. This is the honest cost of a *correct* confidential memcached. */
		for (int t = 0; t < 30; t++) {
			opmr = ibv_reg_mr(c->pd, (char *)c->buf + loff, len, IBV_ACCESS_LOCAL_WRITE);
			if (opmr) break;
			if (errno != EIO) break;
			struct timespec ts = { .tv_sec = 0, .tv_nsec = 200 * 1000 * 1000 };
			nanosleep(&ts, NULL);
		}
		if (!opmr) { perror("e2e reg_mr"); return -1; }
		lkey = opmr->lkey;
	}
	if (ibv_req_notify_cq(c->cq, 0)) { perror("req_notify"); if (opmr) ibv_dereg_mr(opmr); return -1; }
	struct ibv_sge sge = { .addr = (uint64_t)(uintptr_t)c->buf + loff, .length = len, .lkey = lkey };
	struct ibv_send_wr wr = { .wr_id = 1, .sg_list = &sge, .num_sge = 1, .opcode = opcode,
		.send_flags = IBV_SEND_SIGNALED,
		.wr.rdma = { .remote_addr = c->rem_vaddr + roff, .rkey = c->rem_rkey } };
	struct ibv_send_wr *bad = NULL;
	if (ibv_post_send(c->qp, &wr, &bad)) { perror("post_send"); if (opmr) ibv_dereg_mr(opmr); return -1; }
	/* wait for the completion event, then poll (kernel synced the bounced CQ on the IRQ). */
	struct ibv_cq *ev_cq; void *ev_ctx;
	uint64_t deadline = now_ns() + (uint64_t)c->poll_ms * 1000000ULL;
	unsigned events = 0;                 /* unacked comp-channel events */
	int ret = -1;
	for (;;) {
		struct ibv_wc wc;
		int n = ibv_poll_cq(c->cq, 1, &wc);
		if (n < 0) { ret = -1; break; }
		if (n == 1) { ret = (wc.status == IBV_WC_SUCCESS) ? 0 : -1; break; }
		struct pollfd pfd = { .fd = c->chan->fd, .events = POLLIN };
		int ms = (int)((deadline - now_ns()) / 1000000ULL);
		if (ms <= 0) { fprintf(stderr, "completion timeout\n"); ret = -1; break; }
		int pr = poll(&pfd, 1, ms);
		if (pr <= 0) { fprintf(stderr, "completion timeout/poll err\n"); ret = -1; break; }
		if (!ibv_get_cq_event(c->chan, &ev_cq, &ev_ctx)) { events++; ibv_req_notify_cq(c->cq, 0); }
	}
	if (events) ibv_ack_cq_events(c->cq, events);   /* balance get_cq_event */
	if (opmr) ibv_dereg_mr(opmr);   /* dma_unmap: bounce->private sync (read) / release (write) */
	return ret;
}

int rdma_kv_read(struct rdma_conn *c, size_t loff, size_t roff, uint32_t len) {
	if (c->backend) return tcp_do(c, 'R', loff, roff, len);
	return one_sided(c, IBV_WR_RDMA_READ, loff, roff, len);
}
int rdma_kv_write(struct rdma_conn *c, size_t loff, size_t roff, uint32_t len) {
	if (c->backend) return tcp_do(c, 'W', loff, roff, len);
	return one_sided(c, IBV_WR_RDMA_WRITE, loff, roff, len);
}
