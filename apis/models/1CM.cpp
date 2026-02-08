[PROB]

One Compartment Pharmacokinetic Model

[PARAM] @annotated

BW    :  0  : Typical body weight for species (kg)
TVVC  :  0  : Typical value for VC (mL/kg)
TVCL  :  0  : Typical value for CL (mL/h/kg)

[OMEGA] @annotated

nVC   :  0  : Variance of random effect on VC
nCL   :  0  : Variance of random effect on CL

[MAIN]

double VC = TVVC * BW * exp(nVC); // central compartment volume
double CL = TVCL * BW * exp(nCL); // clearance

[CMT] @annotated

CENT   : Drug amount in central compartment (mass)

[GLOBAL]

#define CP (CENT / VC)   // concentration in central compartment

[ODE]

dxdt_CENT   =  - CL * CP;

[CAPTURE] @annotated

CP : Plasma concentration (conc)
VC : Central volume
CL : Clearance
