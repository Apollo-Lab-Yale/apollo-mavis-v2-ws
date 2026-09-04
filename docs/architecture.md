MAVIS v2 (two xArm7 arms on linear tracks: grip arm with gripper + wrist camera,
view arm with wrist camera only) — repository topology:

               interface definitions
                      │
                apollo-mavis-v2-core
                 /          \
                /            \
       implementation     implementation
              │                │
apollo-mavis-v2-hardware        apollo-mavis-v2-sim
                \            /
                 \          /
                  ▼        ▼
               apollo-mavis-v2-runtime
                      │
                apollo-mavis-v2-ui