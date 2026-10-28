| ctx | region | calls | fenced raw ms | est. ms (pipelined) | share of est. pct | GFLOP | GB | TF/s | pct of 62.7 | GB/s | pct of 530 | basis |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| main | embed | 4 | 0.8 | 0.3 | 0.0 | 0.0 | 0.04 | - | - | 143 | 27 | raw-fence |
| main | norm | 516 | 91.2 | 15.1 | 0.4 | 10.7 | 10.74 | 0.7 | 1 | 713 | 134 | microbench |
| main | gdn.proj | 384 | 790.5 | 584.3 | 14.1 | 32985.3 | 19.53 | 56.5 | 90 | 33 | 6 | microbench |
| main | gdn.proj_ba | 192 | 64.3 | 21.6 | 0.5 | 193.3 | 2.20 | 9.0 | 14 | 102 | 19 | microbench |
| main | gdn.conv | 192 | 119.3 | 29.8 | 0.7 | 20.1 | 8.05 | 0.7 | 1 | 270 | 51 | microbench |
| main | gdn.qknorm_bg | 192 | 46.3 | 15.3 | 0.4 | 3.2 | 3.22 | 0.2 | 0 | 210 | 40 | microbench |
| main | gdn.rec | 192 | 239.4 | 185.5 | 4.5 | 927.7 | 7.71 | 5.0 | 8 | 42 | 8 | microbench |
| main | gdn.norm_gate | 192 | 45.6 | 16.3 | 0.4 | 12.1 | 9.66 | 0.7 | 1 | 592 | 112 | microbench |
| main | gdn.out | 192 | 312.6 | 218.9 | 5.3 | 12369.5 | 7.83 | 56.5 | 90 | 36 | 7 | microbench |
| main | resid | 512 | 94.3 | 14.0 | 0.3 | 2.7 | 16.11 | 0.2 | 0 | 1153 | 217 | microbench |
| main | mlp.gateup | 256 | 1990.7 | 1627.6 | 39.4 | 93458.5 | 46.61 | 57.4 | 92 | 29 | 5 | microbench |
| main | mlp.act | 256 | 97.6 | 53.3 | 1.3 | 27.4 | 27.38 | 0.5 | 1 | 514 | 97 | microbench |
| main | mlp.down | 256 | 1142.2 | 884.7 | 21.4 | 46729.2 | 24.65 | 52.8 | 84 | 28 | 5 | microbench |
| main | attn.proj | 192 | 247.7 | 170.3 | 4.1 | 9620.7 | 6.53 | 56.5 | 90 | 38 | 7 | microbench |
| main | attn.qknorm | 64 | 17.4 | 7.4 | 0.2 | 1.9 | 2.62 | 0.3 | 0 | 354 | 67 | microbench |
| main | attn.rope_append | 64 | 25.0 | 3.3 | 0.1 | 0.4 | 1.81 | 0.1 | 0 | 557 | 105 | microbench |
| main | attn.sdpa | 64 | 96.8 | 79.1 | 1.9 | 3299.3 | 2.28 | 41.7 | 67 | 29 | 5 | microbench |
| main | attn.gate | 64 | 12.9 | 2.9 | 0.1 | 1.6 | 2.42 | 0.6 | 1 | 840 | 159 | microbench |
| main | attn.o | 64 | 105.2 | 72.1 | 1.7 | 4123.2 | 2.61 | 57.2 | 91 | 36 | 7 | microbench |
| main | lm_head | 4 | 19.2 | 18.7 | 0.5 | 10.2 | 2.86 | 0.5 | 1 | 153 | 29 | raw-fence |
| mtp | norm | 4 | 0.8 | 0.3 | 0.0 | 0.1 | 0.08 | 0.4 | 1 | 286 | 54 | raw-fence |
| mtp | attn.proj | 12 | 14.3 | 12.7 | 0.3 | 601.3 | 0.41 | 47.2 | 75 | 32 | 6 | raw-fence |
| mtp | attn.qknorm | 4 | 1.2 | 0.7 | 0.0 | 0.1 | 0.16 | 0.1 | 0 | 235 | 44 | raw-fence |
| mtp | attn.rope_append | 4 | 4.9 | 4.4 | 0.1 | 0.0 | 0.11 | - | - | 25 | 5 | raw-fence |
| mtp | attn.sdpa | 4 | 6.8 | 6.3 | 0.2 | 206.2 | 0.14 | 32.8 | 52 | 22 | 4 | raw-fence |
| mtp | attn.gate | 4 | 1.0 | 0.5 | 0.0 | 0.1 | 0.15 | 0.2 | 0 | 312 | 59 | raw-fence |
| mtp | attn.o | 4 | 9.7 | 9.2 | 0.2 | 257.7 | 0.16 | 28.1 | 45 | 17 | 3 | raw-fence |
| mtp | mlp.gateup | 8 | 33.3 | 32.3 | 0.8 | 1460.3 | 0.77 | 45.3 | 72 | 24 | 5 | raw-fence |
| mtp | mlp.act | 4 | 1.8 | 1.3 | 0.0 | 0.4 | 0.43 | 0.3 | 0 | 336 | 63 | raw-fence |
| mtp | mlp.down | 4 | 15.5 | 15.0 | 0.4 | 730.1 | 0.39 | 48.7 | 78 | 26 | 5 | raw-fence |
| mtp | mtp_other | 4 | 34.0 | 33.5 | 0.8 | 0.0 | 0.00 | - | - | 0 | 0 | raw-fence |

SUM est 4136.3 ms vs plain wall 4074.0 ms: +1.5%

| group | est. ms | share of plain wall % |
|---|---:|---:|
| main/embed | 0.3 | 0.0 |
| main/norm | 15.1 | 0.4 |
| main/gdn | 1071.6 | 26.3 |
| main/resid | 14.0 | 0.3 |
| main/mlp | 2565.7 | 63.0 |
| main/attn | 335.0 | 8.2 |
| main/lm_head | 18.7 | 0.5 |
| mtp/norm | 0.3 | 0.0 |
| mtp/attn | 33.7 | 0.8 |
| mtp/mlp | 48.5 | 1.2 |
| mtp/mtp_other | 33.5 | 0.8 |

GDN non-GEMM (rec+conv+qknorm_bg+norm_gate+proj_ba) 268.5 ms = 6.59% of plain wall; rec alone 185.5 ms = 4.55%
