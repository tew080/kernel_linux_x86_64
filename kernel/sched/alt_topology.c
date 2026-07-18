#ifdef ALT_SCHED_DEBUG
#define SCHED_DEBUG_INFO(...)	printk(KERN_INFO __VA_ARGS__)
#else
#define SCHED_DEBUG_INFO(...)	do { } while(0)
#endif

static cpumask_t cpu_topo_masks[6] ____cacheline_aligned_in_smp;

#define sched_ucore_mask	(cpu_topo_masks)
#define sched_pcore_mask	(cpu_topo_masks + 1)
#define sched_ecore_mask	(cpu_topo_masks + 2)

/*
 * pcore_cpus kernel parameter
 */
static int __init pcore_cpus_setup(char *str)
{
	if (cpulist_parse(str, sched_pcore_mask))
		pr_warn("sched/alt: pcore_cpus= incorrect CPU range\n");

	return 1;
}
__setup("pcore_cpus=", pcore_cpus_setup);

/*
 * ultra_core_cpus kernel parameter
 */
static int __init ucore_cpus_setup(char *str)
{
	if (cpulist_parse(str, sched_ucore_mask))
		pr_warn("sched/alt: ucore_cpus= incorrect CPU range\n");

	return 1;
}
__setup("ucore_cpus=", ucore_cpus_setup);

/*
 * CPU topology type
 */
enum cpu_topo_type {
	CPU_TOPOLOGY_DEFAULT	= 0,
	CPU_TOPOLOGY_UCORE,
	CPU_TOPOLOGY_PCORE,
	CPU_TOPOLOGY_ECORE,
	CPU_TOPOLOGY_NONE,
#ifdef CONFIG_SCHED_SMT
	CPU_TOPOLOGY_UCORE_SMT,
	CPU_TOPOLOGY_PCORE_SMT,
	CPU_TOPOLOGY_SMT	= CPU_TOPOLOGY_PCORE_SMT,
	CPU_TOPOLOGY_ECORE_SMT,
#endif
};

#define CPU_TOPOLOGY_MASK	(0x03)

static DEFINE_PER_CPU_READ_MOSTLY(enum cpu_topo_type, sched_cpu_topo);

static __always_inline void sched_set_idle_mask(const unsigned int cpu)
{
	int topo = per_cpu(sched_cpu_topo, cpu);

	switch (topo) {
	case CPU_TOPOLOGY_DEFAULT:
	case CPU_TOPOLOGY_NONE:
		break;
	case CPU_TOPOLOGY_UCORE:
	case CPU_TOPOLOGY_PCORE:
	case CPU_TOPOLOGY_ECORE:
		topo--;
		cpumask_set_cpu(cpu, cpu_sched_prio_mask + topo);
		set_bit(topo, cpu_sched_prio_bitmap);
		break;
#ifdef CONFIG_SCHED_SMT
	case CPU_TOPOLOGY_UCORE_SMT:
	case CPU_TOPOLOGY_PCORE_SMT:
	case CPU_TOPOLOGY_ECORE_SMT:
		topo -= CPU_TOPOLOGY_UCORE_SMT;
		if (cpumask_intersects(cpu_smt_mask(cpu), sched_idle_mask)) {
			cpumask_or(cpu_sched_prio_mask + topo, cpu_sched_prio_mask + topo,
				   cpu_smt_mask(cpu));
			set_bit(topo, cpu_sched_prio_bitmap);

			topo += 3;
			if (!cpumask_andnot(cpu_sched_prio_mask + topo, cpu_sched_prio_mask + topo,
					    cpu_smt_mask(cpu)))
				clear_bit(topo, cpu_sched_prio_bitmap);
		} else {
			topo += 3;
			cpumask_set_cpu(cpu, cpu_sched_prio_mask + topo);
			set_bit(topo, cpu_sched_prio_bitmap);
		}
		break;
#endif
	}

	cpumask_set_cpu(cpu, sched_idle_mask);
	set_bit(SCHED_LEVELS - 1 - IDLE_TASK_SCHED_PRIO, cpu_sched_prio_bitmap);
}

static __always_inline void sched_clear_idle_mask(const unsigned int cpu)
{
	int topo = per_cpu(sched_cpu_topo, cpu);

	switch (topo) {
	case CPU_TOPOLOGY_DEFAULT:
	case CPU_TOPOLOGY_NONE:
		break;
	case CPU_TOPOLOGY_UCORE:
	case CPU_TOPOLOGY_PCORE:
	case CPU_TOPOLOGY_ECORE:
		topo--;
		cpumask_clear_cpu(cpu, cpu_sched_prio_mask + topo);
		if (cpumask_empty(cpu_sched_prio_mask + topo))
			clear_bit(topo, cpu_sched_prio_bitmap);
		break;
#ifdef CONFIG_SCHED_SMT
	case CPU_TOPOLOGY_UCORE_SMT:
	case CPU_TOPOLOGY_PCORE_SMT:
	case CPU_TOPOLOGY_ECORE_SMT:
		topo -= CPU_TOPOLOGY_UCORE_SMT;
		if (cpumask_test_cpu(cpu, cpu_sched_prio_mask + topo)) {
			if (!cpumask_andnot(cpu_sched_prio_mask + topo, cpu_sched_prio_mask + topo,
					    cpu_smt_mask(cpu)))
				clear_bit(topo, cpu_sched_prio_bitmap);

			topo += 3;
			cpumask_or(cpu_sched_prio_mask + topo, cpu_sched_prio_mask + topo,
				   per_cpu(cpu_affinity_masks, cpu));
			set_bit(topo, cpu_sched_prio_bitmap);
		} else {
			topo += 3;
			cpumask_clear_cpu(cpu, cpu_sched_prio_mask + topo);
			if (cpumask_empty(cpu_sched_prio_mask + topo))
				clear_bit(topo, cpu_sched_prio_bitmap);
		}
		break;
#endif
	}

	cpumask_clear_cpu(cpu, sched_idle_mask);
	if (cpumask_empty(sched_idle_mask))
		clear_bit(SCHED_LEVELS - 1 - IDLE_TASK_SCHED_PRIO, cpu_sched_prio_bitmap);
}


/*
 * CPU topology balance type
 */
static DEFINE_PER_CPU(struct balance_callback, active_balance_head);

/* common balance functions */
static int active_balance_cpu_stop(void *data)
{
	struct balance_arg *arg = data;
	unsigned long flags;

	local_irq_save(flags);
	arg->active = 0;
	local_irq_restore(flags);

	return 0;
}

/* trigger_active_balance - for @cpu */
static __always_inline int
trigger_active_balance(const int cpu, struct rq *src_rq, cpumask_t *target_mask)
{
	struct rq *rq = cpu_rq(cpu);
	struct balance_arg *arg;
	unsigned long flags;
	struct task_struct *p;
	int res;

	if (!raw_spin_trylock_irqsave(&rq->lock, flags))
		return 0;

	arg = &rq->active_balance_arg;
	p = rq->curr;
	res = (p != rq->idle) && (0 == srq_nr_queued(cpu)) && is_preempt_list_empty(cpu) &&	\
	      !is_migration_disabled(p) && cpumask_intersects(p->cpus_ptr, target_mask) &&	\
	      !arg->active;
	if (res)
		arg->active = 1;

	raw_spin_unlock_irqrestore(&rq->lock, flags);

	if (res) {
		preempt_disable();
		raw_spin_unlock(&src_rq->lock);

		stop_one_cpu_nowait(cpu, active_balance_cpu_stop, arg, &rq->active_balance_work);

		preempt_enable();
		raw_spin_lock(&src_rq->lock);
	}

	return res;
}

static __always_inline void cpu_topo_balance(struct rq *rq)
{
	int i, cpu = cpu_of(rq);
	int idx = (per_cpu(sched_cpu_topo, cpu) & CPU_TOPOLOGY_MASK) - 1;
	cpumask_t *target_mask = cpu_sched_prio_mask + idx;

#ifdef CONFIG_SCHED_SMT
	for (int level = 3; level < 6; level++) {
		if (cpumask_empty(cpu_topo_masks + level))
			continue;

		for_each_cpu_andnot(i, cpu_topo_masks + level, sched_idle_mask) {
			if (!cpumask_intersects(cpu_smt_mask(i), sched_idle_mask) &&
			    trigger_active_balance(i, rq, target_mask))
				return;
		}
	}
#endif /* CONFIG_SCHED_SMT */

	if (2 != idx) {
		for_each_cpu_andnot(i, sched_ecore_mask, sched_idle_mask) {
			if (trigger_active_balance(i, rq, target_mask))
				return;
		}
	}
}

static inline void sched_cpu_topology_balance(const unsigned int cpu, struct rq *rq)
{
	const int topo = per_cpu(sched_cpu_topo, cpu);
	switch (topo) {
	case CPU_TOPOLOGY_DEFAULT:
		break;
	case CPU_TOPOLOGY_UCORE:
	case CPU_TOPOLOGY_PCORE:
#ifdef CONFIG_SCHED_SMT
	case CPU_TOPOLOGY_ECORE:
#endif
		queue_balance_callback(rq, &per_cpu(active_balance_head, cpu), cpu_topo_balance);
		break;
	case CPU_TOPOLOGY_UCORE_SMT:
	case CPU_TOPOLOGY_PCORE_SMT: /* as same as CPU_TOPOLOGY_SMT */
	case CPU_TOPOLOGY_ECORE_SMT:
		int idx = (topo & CPU_TOPOLOGY_MASK) - 1;

		if (bitmap_empty(cpu_sched_prio_bitmap, idx) &&
		    cpumask_test_cpu(cpu, cpu_sched_prio_mask + idx))
			queue_balance_callback(rq, &per_cpu(active_balance_head, cpu),
					       cpu_topo_balance);
		break;
	}
}

/*
 * Keep a unique ID per domain (we use the first CPUs number in the cpumask of
 * the domain), this allows us to quickly tell if two cpus are in the same cache
 * domain, see cpus_share_cache().
 */
static DEFINE_PER_CPU_READ_MOSTLY(int, sd_llc_id);

bool cpus_share_cache(int this_cpu, int that_cpu)
{
	if (this_cpu == that_cpu)
		return true;

	return per_cpu(sd_llc_id, this_cpu) == per_cpu(sd_llc_id, that_cpu);
}


/*
 * CPU topology mask
 */
DEFINE_PER_CPU_ALIGNED(cpumask_t [NR_CPU_AFFINITY_LEVELS], cpu_affinity_masks);
DEFINE_PER_CPU_ALIGNED(cpumask_t *, cpu_affinity_end_mask);

static inline void sched_init_topology_early(void)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		/* init topo masks */
		cpumask_t *tmp = per_cpu(cpu_affinity_masks, cpu);

		cpumask_copy(tmp, cpu_possible_mask);
		per_cpu(cpu_affinity_end_mask, cpu) = ++tmp;
	}
}

/* init schedule cpu topology masks: ucore/pcore/ecore and smt mask */
static inline void sched_init_cpu_topology(void)
{
	bool cpu_topo_smt_present = false;

#ifdef CONFIG_SCHED_SMT
	if (!cpumask_empty(&sched_smt_mask)) {
		printk(KERN_INFO "sched: (smt) mask : 0x%08lx\n", sched_smt_mask.bits[0]);
		if (cpumask_empty(sched_pcore_mask))
			cpumask_copy(sched_pcore_mask, &sched_smt_mask);
	}
#endif

	if (cpumask_empty(sched_pcore_mask) && cpumask_empty(sched_ucore_mask))
		return;

	cpumask_andnot(sched_pcore_mask, sched_pcore_mask, sched_ucore_mask);

	cpumask_andnot(sched_ecore_mask, cpu_online_mask, sched_pcore_mask);
	cpumask_andnot(sched_ecore_mask, sched_ecore_mask, sched_ucore_mask);

	printk(KERN_INFO "sched: topo  ucore: 0x%08lx, pcore: 0x%08lx, ecore: 0x%08lx\n",
	       sched_ucore_mask->bits[0],
	       sched_pcore_mask->bits[0],
	       sched_ecore_mask->bits[0]);

#ifdef CONFIG_SCHED_SMT
	if (cpumask_empty(&sched_smt_mask))
		return;

	for (int i = 0; i < 3; i++)
		if (cpumask_and(cpu_topo_masks + i + 3,
				cpu_topo_masks + i, &sched_smt_mask))
			cpu_topo_smt_present = true;

	if (!cpu_topo_smt_present)
		return;

	printk(KERN_INFO "sched: (smt) ucore: 0x%08lx, pcore: 0x%08lx, ecore: 0x%08lx\n",
	       (sched_ucore_mask + 3)->bits[0],
	       (sched_pcore_mask + 3)->bits[0],
	       (sched_ecore_mask + 3)->bits[0]);
#endif
}

#define TOPOLOGY_CPUMASK(name, mask, last)					\
	if (cpumask_and(topo, topo, mask)) {					\
		printk(KERN_INFO "sched: cpu#%02d affinity: 0x%08lx - "#name,	\
		       cpu, (topo++)->bits[0]);					\
	}									\
	if (!last)								\
		bitmap_complement(cpumask_bits(topo), cpumask_bits(mask),	\
				  nr_cpumask_bits);

static inline void sched_init_topology(void)
{
	int cpu;

	sched_init_cpu_topology();

	/* CPU topology setup */
	for_each_online_cpu(cpu) {
		cpumask_t *topo;
		int cpu_topo = 0;
#ifdef CONFIG_SCHED_SMT
		if (cpumask_weight(cpu_smt_mask(cpu)) > 1)
			cpu_topo += CPU_TOPOLOGY_NONE;
#endif
		if (cpumask_test_cpu(cpu, sched_ucore_mask))
			cpu_topo += CPU_TOPOLOGY_UCORE;
		else if (cpumask_test_cpu(cpu, sched_pcore_mask))
			cpu_topo += CPU_TOPOLOGY_PCORE;
		else if (cpumask_test_cpu(cpu, sched_ecore_mask))
			cpu_topo += CPU_TOPOLOGY_ECORE;

		if (cpu_topo)
			per_cpu(sched_cpu_topo, cpu) = cpu_topo;

		topo = per_cpu(cpu_affinity_masks, cpu);

		bitmap_complement(cpumask_bits(topo), cpumask_bits(cpumask_of(cpu)),
				  nr_cpumask_bits);
#ifdef CONFIG_SCHED_SMT
		TOPOLOGY_CPUMASK(smt, topology_sibling_cpumask(cpu), false);
#endif /* CONFIG_SCHED_SMT */
		TOPOLOGY_CPUMASK(cluster, topology_cluster_cpumask(cpu), false);

		per_cpu(sd_llc_id, cpu) = cpumask_first(cpu_coregroup_mask(cpu));
		TOPOLOGY_CPUMASK(coregroup, cpu_coregroup_mask(cpu), false);

		TOPOLOGY_CPUMASK(core, topology_core_cpumask(cpu), false);

		TOPOLOGY_CPUMASK(others, cpu_online_mask, true);

		per_cpu(cpu_affinity_end_mask, cpu) = topo;

		SCHED_DEBUG_INFO("sched: cpu#%02d topology: %d%5s, llc_id = %d",
				 cpu, cpu_topo & CPU_TOPOLOGY_MASK,
				 (cpu_topo > CPU_TOPOLOGY_MASK) ? "(smt)" : "",
				 per_cpu(sd_llc_id, cpu));
	}
}
