#ifndef _KERNEL_SCHED_ALT_CORE_H
#define _KERNEL_SCHED_ALT_CORE_H

/*
 * Compile time debug macro
 * #define ALT_SCHED_DEBUG
 */
#define ALT_SCHED_DEBUG

#ifdef ALT_SCHED_DEBUG
extern void alt_sched_debug(void);
#else
static inline void alt_sched_debug(void) {}
#endif

/* preempt list function */
DECLARE_PER_CPU_SHARED_ALIGNED(struct llist_head, preempt_list);

static inline bool is_preempt_list_empty(const int cpu)
{
	return llist_empty(per_cpu_ptr(&preempt_list, cpu));
}

/*
 * Task related inlined functions
 */
static inline bool is_migration_disabled(const struct task_struct *p)
{
	return p->migration_disabled;
}

/* rt_prio(prio) defined in include/linux/sched/rt.h */
#define rt_task(p)		rt_prio((p)->prio)
#define rt_policy(policy)	((policy) == SCHED_FIFO || (policy) == SCHED_RR)
#define task_has_rt_policy(p)	(rt_policy((p)->policy))

#define fair_policy(policy)	((policy) == SCHED_NORMAL || (policy) == SCHED_BATCH)

#define valid_policy(policy)	((policy) <= SCHED_IDLE)

#define task_has_dl_policy(p)	(false)
#define dl_prio(prio)		(false)

struct affinity_context {
	const struct cpumask	*new_mask;
	struct cpumask		*user_mask;
	unsigned int		flags;
};

/* CONFIG_SCHED_CLASS_EXT is not supported */
#define scx_switched_all()	false

#define SCA_CHECK		0x01
/* SCA_MIGRATE_DISABLE & SCA_MIGRATE_ENABLE is not supported */
//#define SCA_MIGRATE_DISABLE	0x02
//#define SCA_MIGRATE_ENABLE	0x04
#define SCA_USER		0x08

extern int __set_cpus_allowed_ptr(struct task_struct *p, struct affinity_context *ctx);

static inline cpumask_t *alloc_user_cpus_ptr(int node)
{
	/*
	 * See set_cpus_allowed_force() above for the rcu_head usage.
	 */
	int size = max_t(int, cpumask_size(), sizeof(struct rcu_head));

	return kmalloc_node(size, GFP_KERNEL, node);
}

#ifdef CONFIG_RT_MUTEXES

static inline int __rt_effective_prio(struct task_struct *pi_task, int prio)
{
	if (pi_task)
		prio = min(prio, pi_task->prio);

	return prio;
}

static inline int rt_effective_prio(struct task_struct *p, int prio)
{
	struct task_struct *pi_task = rt_mutex_get_top_task(p);

	return __rt_effective_prio(pi_task, prio);
}

#else /* !CONFIG_RT_MUTEXES: */

static inline int rt_effective_prio(struct task_struct *p, int prio)
{
	return prio;
}

#endif /* !CONFIG_RT_MUTEXES */

extern int __sched_setscheduler(struct task_struct *p, const struct sched_attr *attr, bool user, bool pi);
extern int __sched_setaffinity(struct task_struct *p, struct affinity_context *ctx);

extern void wakeup_modified_task(struct task_struct *p);

/*
 * run queue related inlined functions
 */
static __always_inline
struct llist_node *sched_llist_del(struct llist_node **curr, struct llist_node *target)
{
	struct llist_node *entry;

	while (*curr) {
		entry = *curr;

		if (entry == target) {
			*curr = entry->next;
			entry = container_of(curr, struct llist_node, next);
			while (entry->next)
				entry = entry->next;

			return entry;
		}
		curr = &entry->next;
	}
	WARN_ONCE(true, "sched/alt: llist_del() target should be in list\n");
	return NULL;
}

static __always_inline
void sched_llist_merge(struct llist_head *head, struct llist_node *first, struct llist_node *last)
{
	while (!llist_add_batch(first, last, head)) {
		struct llist_node *node, *new_first = llist_del_all(head);

		/* move [first, last] to the tail */
		for (node = last->next; node->next; node = node->next);
		node->next = first;

		/* merge new first if any */
		if (new_first != first) {
			for (node = new_first; first != node->next; node = node->next);
			node->next = last->next;
			first = new_first;
		} else {
			first = last->next;
		}
		/* terminal the tail */
		last->next = NULL;
	}
}

#define SRQ_DEQUEUE_TASK(srq, p, __modify_body__)					\
{											\
	int idx = READ_ONCE(p->__sched_prio);						\
	struct llist_head *head = &srq->_head[idx];					\
	struct llist_node *last, *first = llist_del_all(head);				\
											\
	last = sched_llist_del(&first, &p->pq_node);					\
	if (first) {									\
		sched_llist_merge(head, first, last);					\
	} else if (llist_empty(head)) {							\
		WARN_ONCE(task_sched_prio(p) != idx, "sched: srq en/dequeue bug.\n");	\
		clear_bit(idx, srq->bitmap);						\
		smp_rmb();								\
		if (!llist_empty(head))							\
			set_bit(idx, srq->bitmap);					\
	}										\
	__modify_body__									\
	WRITE_ONCE(p->__sched_prio, -1);						\
	atomic_dec(&srq->nr_queued);							\
}

#define SRQ_ENQUEUE_TASK(srq, p, __modify_body__)		\
{								\
	int sched_prio = task_sched_prio(p);			\
								\
	WRITE_ONCE(p->__sched_prio, sched_prio);		\
	__modify_body__						\
	if (llist_add(&p->pq_node, &(srq)->_head[sched_prio]))	\
		set_bit(sched_prio, (srq)->bitmap);		\
	atomic_inc(&(srq)->nr_queued);				\
}

/*
 * Context API
 */
static inline struct rq *__task_modify_lock(struct task_struct *p, struct rq_flags *rf)
{
	for (;;) {
		if (TASK_ON_RQ_WAKING == p->on_rq) {
			struct rq *rq = cpu_rq(p->wake_cpu);

			raw_spin_lock(&rq->lock);
			if (likely(TASK_ON_RQ_WAKING == p->on_rq && rq == task_rq(p))) {
				rf->lock = &rq->lock;
				rf->queued = false;
				return rq;
			}
			raw_spin_unlock(&rq->lock);
		} else if (task_on_rq_queued(p)) {
			int idx;
			if (p->on_cpu) {
				struct rq *rq = task_rq(p);

				raw_spin_lock(&rq->lock);
				if (likely(task_on_rq_queued(p) && p->on_cpu && rq == task_rq(p))) {
					rf->lock = &rq->lock;
					rf->queued = false;
					return rq;
				}
				raw_spin_unlock(&rq->lock);
			} else if ((idx = READ_ONCE(p->__sched_prio)) != -1) {
				struct sched_run_queue *srq = cpu_srq(0);
				raw_spinlock_t *lock = &srq->_lock[idx];

				raw_spin_lock(lock);
				if (task_on_rq_queued(p) && !p->on_cpu &&
				    idx == READ_ONCE(p->__sched_prio)) {

					SRQ_DEQUEUE_TASK(srq, p, {
							 WRITE_ONCE(p->on_rq, TASK_ON_RQ_MIGRATING);
							 });

					raw_spin_unlock(lock);

					rf->lock = NULL;
					rf->queued = true;
					return task_rq(p);
				}
				raw_spin_unlock(lock);
			}
		} else if (task_on_rq_migrating(p)) {
			do {
				cpu_relax();
			} while (unlikely(task_on_rq_migrating(p)));
		} else {
			rf->lock = NULL;
			rf->queued = false;
			return task_rq(p);
		}
	}
}

static inline void __task_modify_unlock(struct task_struct *p, struct rq_flags *rf)
{
	if (NULL != rf->lock)
		raw_spin_unlock(rf->lock);
	if (rf->queued)
		wakeup_modified_task(p);
}

static inline struct rq *task_access_lock(struct task_struct *p, struct rq_flags *rf)
{
	raw_spin_lock_irqsave(&p->pi_lock, rf->flags);
	return __task_modify_lock(p, rf);
}

static inline void task_access_unlock(struct task_struct *p, struct rq_flags *rf)
{
	__task_modify_unlock(p, rf);
	raw_spin_unlock_irqrestore(&p->pi_lock, rf->flags);
}

DEFINE_LOCK_GUARD_1(task_access_lock, struct task_struct,
		    _T->rq = task_access_lock(_T->lock, &_T->rf),
		    task_access_unlock(_T->lock, &_T->rf),
		    struct rq *rq; struct rq_flags rf)

#define task_rq_lock(...) _task_rq_lock(__VA_ARGS__)
extern struct rq *_task_rq_lock(struct task_struct *p, struct rq_flags *rf);

static inline void
task_rq_unlock(struct rq *rq, struct task_struct *p, struct rq_flags *rf)
{
	raw_spin_unlock(&rq->lock);
	raw_spin_unlock_irqrestore(&p->pi_lock, rf->flags);
}

DEFINE_LOCK_GUARD_1(task_rq_lock, struct task_struct,
		    _T->rq = task_rq_lock(_T->lock, &_T->rf),
		    task_rq_unlock(_T->rq, _T->lock, &_T->rf),
		    struct rq *rq; struct rq_flags rf)

extern void yield_task(struct rq *rq);

DECLARE_STATIC_KEY_FALSE(sched_smt_present);

/* balance callback */
extern struct balance_callback *splice_balance_callbacks(struct rq *rq);
extern void balance_callbacks(struct rq *rq, struct balance_callback *head);

#endif /* _KERNEL_SCHED_ALT_CORE_H */
