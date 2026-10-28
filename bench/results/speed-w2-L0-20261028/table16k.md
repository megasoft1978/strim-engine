| ctx | region | calls | fenced raw ms | est. ms (pipelined) | share of est. pct | GFLOP | GB | TF/s | pct of 62.7 | GB/s | pct of 530 | basis |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| main | embed | 16 | 3.0 | 0.7 | 0.0 | 0.0 | 0.17 | - | - | 244 | 46 | raw-fence |
| main | norm | 2064 | 338.3 | 60.3 | 0.3 | 43.0 | 42.95 | 0.7 | 1 | 713 | 134 | microbench |
| main | gdn.proj | 1536 | 3107.7 | 2337.0 | 13.3 | 131941.4 | 78.11 | 56.5 | 90 | 33 | 6 | microbench |
| main | gdn.proj_ba | 768 | 271.9 | 86.2 | 0.5 | 773.1 | 8.81 | 9.0 | 14 | 102 | 19 | microbench |
| main | gdn.conv | 768 | 391.7 | 119.2 | 0.7 | 80.5 | 32.21 | 0.7 | 1 | 270 | 51 | microbench |
| main | gdn.qknorm_bg | 768 | 178.9 | 61.3 | 0.3 | 12.9 | 12.88 | 0.2 | 0 | 210 | 40 | microbench |
| main | gdn.rec | 768 | 936.5 | 741.9 | 4.2 | 3710.9 | 30.83 | 5.0 | 8 | 42 | 8 | microbench |
| main | gdn.norm_gate | 768 | 183.0 | 65.3 | 0.4 | 48.3 | 38.65 | 0.7 | 1 | 592 | 112 | microbench |
| main | gdn.out | 768 | 1148.1 | 875.5 | 5.0 | 49478.0 | 31.31 | 56.5 | 90 | 36 | 7 | microbench |
| main | resid | 2048 | 438.8 | 55.9 | 0.3 | 10.7 | 64.42 | 0.2 | 0 | 1152 | 217 | microbench |
| main | mlp.gateup | 1024 | 7567.8 | 6510.6 | 37.2 | 373834.0 | 186.43 | 57.4 | 92 | 29 | 5 | microbench |
| main | mlp.act | 1024 | 420.5 | 213.2 | 1.2 | 109.5 | 109.52 | 0.5 | 1 | 514 | 97 | microbench |
| main | mlp.down | 1024 | 4331.8 | 3538.9 | 20.2 | 186917.0 | 98.58 | 52.8 | 84 | 28 | 5 | microbench |
| main | attn.proj | 768 | 984.6 | 681.2 | 3.9 | 38482.9 | 26.14 | 56.5 | 90 | 38 | 7 | microbench |
| main | attn.qknorm | 256 | 69.1 | 29.6 | 0.2 | 7.5 | 10.47 | 0.3 | 0 | 354 | 67 | microbench |
| main | attn.rope_append | 256 | 223.5 | 13.0 | 0.1 | 1.4 | 7.25 | 0.1 | 0 | 557 | 105 | microbench |
| main | attn.sdpa | 256 | 1356.7 | 1240.8 | 7.1 | 52779.8 | 15.57 | 42.5 | 68 | 13 | 2 | microbench |
| main | attn.gate | 256 | 63.3 | 11.5 | 0.1 | 6.4 | 9.66 | 0.6 | 1 | 839 | 158 | microbench |
| main | attn.o | 256 | 412.7 | 288.3 | 1.6 | 16492.7 | 10.44 | 57.2 | 91 | 36 | 7 | microbench |
| main | lm_head | 16 | 86.1 | 83.8 | 0.5 | 40.7 | 11.45 | 0.5 | 1 | 137 | 26 | raw-fence |
| mtp | norm | 16 | 3.4 | 1.1 | 0.0 | 0.3 | 0.34 | 0.3 | 0 | 310 | 59 | raw-fence |
| mtp | attn.proj | 48 | 67.5 | 60.6 | 0.3 | 2405.2 | 1.63 | 39.7 | 63 | 27 | 5 | raw-fence |
| mtp | attn.qknorm | 16 | 4.4 | 2.1 | 0.0 | 0.5 | 0.65 | 0.2 | 0 | 310 | 59 | raw-fence |
| mtp | attn.rope_append | 16 | 12.6 | 10.3 | 0.1 | 0.1 | 0.45 | 0.0 | 0 | 44 | 8 | raw-fence |
| mtp | attn.sdpa | 16 | 83.2 | 80.9 | 0.5 | 3298.7 | 0.97 | 40.8 | 65 | 12 | 2 | raw-fence |
| mtp | attn.gate | 16 | 4.0 | 1.7 | 0.0 | 0.4 | 0.60 | 0.2 | 0 | 354 | 67 | raw-fence |
| mtp | attn.o | 16 | 28.1 | 25.8 | 0.1 | 1030.8 | 0.65 | 40.0 | 64 | 25 | 5 | raw-fence |
| mtp | mlp.gateup | 32 | 118.7 | 114.1 | 0.7 | 5841.2 | 3.08 | 51.2 | 82 | 27 | 5 | raw-fence |
| mtp | mlp.act | 16 | 6.9 | 4.6 | 0.0 | 1.7 | 1.71 | 0.4 | 1 | 372 | 70 | raw-fence |
| mtp | mlp.down | 16 | 61.4 | 59.1 | 0.3 | 2920.6 | 1.54 | 49.4 | 79 | 26 | 5 | raw-fence |
| mtp | mtp_other | 16 | 138.4 | 136.1 | 0.8 | 0.0 | 0.00 | - | - | 0 | 0 | raw-fence |

SUM est 17510.6 ms vs plain wall 17335.0 ms: +1.0%

| group | est. ms | share of plain wall % |
|---|---:|---:|
| main/embed | 0.7 | 0.0 |
| main/norm | 60.3 | 0.3 |
| main/gdn | 4286.4 | 24.7 |
| main/resid | 55.9 | 0.3 |
| main/mlp | 10262.7 | 59.2 |
| main/attn | 2264.4 | 13.1 |
| main/lm_head | 83.8 | 0.5 |
| mtp/norm | 1.1 | 0.0 |
| mtp/attn | 181.4 | 1.0 |
| mtp/mlp | 177.8 | 1.0 |
| mtp/mtp_other | 136.1 | 0.8 |

GDN non-GEMM (rec+conv+qknorm_bg+norm_gate+proj_ba) 1073.9 ms = 6.19% of plain wall; rec alone 741.9 ms = 4.28%
