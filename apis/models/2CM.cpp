[PROB]

Two Compartment Pharmacokinetic Model

[PARAM] @annotated

BW    :  0  : Typical body weight for species (kg)
TVVC  :  0  : Typical value for VC (mL/kg)
TVVP  :  0  : Typical value for VP (mL/kg)
TVCL  :  0  : Typical value for CL (mL/h/kg)
TVQ   :  0  : Typical value for Q (mL/h/kg)

[OMEGA] @annotated

nVC   :  0  : Variance of random effect on VC
nVP   :  0  : Variance of random effect on VP
nCL   :  0  : Variance of random effect on CL
nQ    :  0  : Variance of random effect on Q

[MAIN]

double VC = TVVC * BW * exp(nVC); // central compartment volume
double VP = TVVP * BW * exp(nVP); // peripheral compartment volume
double CL = TVCL * BW * exp(nCL); // clearance
double Q  = TVQ  * BW * exp(nQ);  // intercompartmental clearance

[CMT] @annotated

CENT   : Drug amount in central compartment (mass)
PERIPH : Drug amount in peripherhal compartment (mass)

[GLOBAL]

#define CP (CENT / VC)   // concentration in central compartment
#define CT (PERIPH / VP) // concentration in peripheral compartment

[ODE]

dxdt_CENT   =  - (CL + Q) * CP + (Q * CT);
dxdt_PERIPH =  (Q * CP) - (Q * CT);

[CAPTURE] @annotated

CP : Plasma concentration (conc)
CT : Peripheral tissue concentration (conc)
VC : Central volume
VP : Peripheral volume
CL : Clearance
Q  : Distributional clearance
