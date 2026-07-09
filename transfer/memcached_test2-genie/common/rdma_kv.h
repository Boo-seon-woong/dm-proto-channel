/* rdma_kv — minimal one-sided RC RDMA transport for the disaggregated memcached
 * store. Compute node = client (initiator); memory node = server (passive target
 * exposing one region). Event-driven completion (arm + wait on the comp channel)
 * so the ITRC-RDMA SEV path works: the coherent-WQ kernel syncs the bounced CQ on
 * the completion IRQ before the event wakes us. Adapted from sev-to-mn/src/snp_rdma_test.c. */
#ifndef RDMA_KV_H
#define RDMA_KV_H
#include <stdint.h>
#include <stddef.h>
#include <infiniband/verbs.h>

struct rdma_conn {
	struct ibv_context *ctx;
	struct ibv_pd *pd;
	struct ibv_cq *cq;
	struct ibv_comp_channel *chan;
	struct ibv_qp *qp;
	struct ibv_mr *mr;      /* local buffer MR */
	void *buf;              /* local buffer base */
	size_t buf_size;
	/* remote (peer) region, filled after connect/accept */
	uint64_t rem_vaddr;
	uint32_t rem_rkey;
	int poll_ms;            /* completion wait timeout */
	int e2e;                /* 1 = per-op reg/dereg so read data reaches PRIVATE memory (SEV) */
	int backend;            /* 0 = RDMA one-sided (default); 1 = TCP request/response backend */
	int peer_fd;            /* RDMA: liveness channel. TCP backend: the data socket to the memory node. */
};

/* Open device, PD, CQ (+comp channel), QP, and register `buf` (buf_size) with
 * local + remote read/write access. Returns 0 on success. */
int rdma_kv_open(struct rdma_conn *c, const char *dev, int ib_port,
		 void *buf, size_t buf_size);

/* Memory node: listen on tcp_port, accept ONE compute node, exchange QP+MR info,
 * bring the QP to RTS. The peer can then one-sided read/write our `buf`. */
int rdma_kv_serve(struct rdma_conn *c, int ib_port, int tcp_port);

/* Compute node: connect to memory node ip:tcp_port, exchange, RTS. Fills
 * rem_vaddr/rem_rkey (the memory node's region). */
int rdma_kv_connect(struct rdma_conn *c, int ib_port, const char *ip, int tcp_port);

/* TCP-backend ablation: same fixed-slot store, but the memory node is reached over a plain TCP
 * request/response socket instead of one-sided RDMA. Isolates transport (TCP vs RDMA) with the
 * SAME KVS structure and topology (remote memory node = genie). No RDMA device/QP/MR is used. */
int rdma_kv_connect_tcp(struct rdma_conn *c, const char *ip, int tcp_port, void *buf, size_t buf_size);

/* Memory node, TCP backend: serve the fixed-slot store to one compute node over TCP. */
int rdma_kv_serve_tcp(int tcp_port, void *store, size_t store_size);

/* One-sided ops: transfer `len` bytes between local `buf+loff` and the remote
 * region at `roff` (offset within the memory node's region). Blocking (waits for
 * completion, event-driven). Returns 0 on success. */
int rdma_kv_read(struct rdma_conn *c, size_t loff, size_t roff, uint32_t len);
int rdma_kv_write(struct rdma_conn *c, size_t loff, size_t roff, uint32_t len);

#endif
