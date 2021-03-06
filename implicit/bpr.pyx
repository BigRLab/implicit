import cython
import logging
import multiprocessing
import random
import time

from cython.parallel import parallel, prange
from libc.math cimport exp
from libcpp.vector cimport vector

import numpy as np
import scipy.sparse

import implicit.cuda

from .recommender_base import MatrixFactorizationBase


cdef extern from "<random>" namespace "std":
    cdef cppclass mt19937:
        mt19937(unsigned int)

    cdef cppclass uniform_int_distribution[T]:
        uniform_int_distribution(int, int)
        T operator()(mt19937) nogil


log = logging.getLogger("implicit")

# thin wrapper around omp_get_thread_num (since referencing directly will cause OSX
# build to fail)
cdef extern from "bpr.h" namespace "implicit" nogil:
    cdef int get_thread_num()


class BayesianPersonalizedRanking(MatrixFactorizationBase):
    """ Bayesian Personalized Ranking

    A recommender model that learns  a matrix factorization embedding based off minimizing the
    pairwise ranking loss described in the paper `BPR: Bayesian Personalized Ranking from Implicit
    Feedback <https://arxiv.org/pdf/1205.2618.pdf>`_.

    Parameters
    ----------
    factors : int, optional
        The number of latent factors to compute
    learning_rate : float, optional
        The learning rate to apply for SGD updates during training
    regularization : float, optional
        The regularization factor to use
    use_gpu : bool, optional
        Fit on the GPU if available
    iterations : int, optional
        The number of training epochs tro use when fitting the data
    num_threads : int, optional
        The number of threads to use for fitting the model. This only
        applies for the native extensions. Specifying 0 means to default
        to the number of cores on the machine.

    Attributes
    ----------
    item_factors : ndarray
        Array of latent factors for each item in the training set
    user_factors : ndarray
        Array of latent factors for each user in the training set
    """
    def __init__(self, factors=100, learning_rate=0.05, regularization=0.01, iterations=100,
                 use_gpu=False, num_threads=0):
        super(BayesianPersonalizedRanking, self).__init__()

        self.factors = factors
        self.learning_rate = learning_rate
        self.iterations = iterations
        self.regularization = regularization
        self.use_gpu = use_gpu
        self.num_threads = num_threads

    @cython.cdivision(True)
    @cython.boundscheck(False)
    def fit(self, item_users):
        """ Factorizes the item_users matrix

        Parameters
        ----------
        item_users: coo_matrix
            Matrix of confidences for the liked items. This matrix should be a coo_matrix where
            the rows of the matrix are the item, and the columns are the users that liked that item.
            BPR ignores the weight value of the matrix right now - it treats non zero entries
            as a binary signal that the user liked the item.
        """

        # we need a COO matrix here to do this efficiently, convert if necessary
        Ciu = item_users
        if not isinstance(Ciu, scipy.sparse.coo_matrix):
            s = time.time()
            log.debug("Converting input to COO format")
            Ciu = Ciu.tocoo()
            log.debug("Converted input to COO in %.3fs", time.time() - s)

        # for now, all we handle is float 32 values
        if Ciu.dtype != np.float32:
            Ciu = Ciu.astype(np.float32)
        # initialize factors
        items, users = Ciu.shape

        # create factors if not already created.
        # Note: the final dimension is for the item bias term - which is set to a 1 for all users
        # this simplifies interfacing with approximate nearest neighbours libraries etc
        if self.item_factors is None:
            self.item_factors = np.random.rand(items, self.factors + 1).astype(np.float32)

            # set factors to all zeros for items without any ratings
            self.item_factors[np.bincount(Ciu.row) == 0] = np.zeros(self.factors + 1)

        if self.user_factors is None:
            self.user_factors = np.random.rand(users, self.factors + 1).astype(np.float32)

            # set factors to all zeros for users without any ratings
            self.user_factors[np.bincount(Ciu.col) == 0] = np.zeros(self.factors + 1)

            self.user_factors[:, self.factors] = 1.0

        if self.use_gpu:
            return self._fit_gpu(Ciu)

        # we accept num_threads = 0 as indicating to create as many threads as we have cores,
        # but in that case we need the number of cores, since we need to initialize RNG state per
        # thread. Get the appropiate value back from openmp
        cdef int num_threads = self.num_threads
        if not num_threads:
            num_threads = multiprocessing.cpu_count()

        # initialize RNG's, one per thread.
        cdef vector[mt19937] rng
        cdef vector[uniform_int_distribution[int]] dist
        for i in range(num_threads):
            rng.push_back(mt19937(np.random.randint(2**31)))
            dist.push_back(uniform_int_distribution[int](0, len(Ciu.row) - 1))

        for epoch in range(self.iterations):
            start = time.time()
            correct = bpr_update(rng, dist, Ciu.col, Ciu.row,
                                 self.user_factors, self.item_factors,
                                 self.learning_rate, self.regularization, num_threads)
            log.debug("fit epoch %i in %.3fs (%.2f%% ranked correctly)", epoch,
                      (time.time() - start), 100.0 * correct / len(Ciu.row))

    def _fit_gpu(self, Ciu_host):
        if not implicit.cuda.HAS_CUDA:
            raise ValueError("No CUDA extension has been built, can't train on GPU.")

        Ciu = implicit.cuda.CuCOOMatrix(Ciu_host)
        X = implicit.cuda.CuDenseMatrix(self.user_factors.astype(np.float32))
        Y = implicit.cuda.CuDenseMatrix(self.item_factors.astype(np.float32))

        for epoch in range(self.iterations):
            start = time.time()
            correct = implicit.cuda.cu_bpr_update(Ciu, X, Y, self.learning_rate,
                                                  self.regularization, np.random.randint(2**31))
            log.debug("fit epoch %i in %.3fs (%.2f%% ranked correctly)", epoch,
                      (time.time() - start), 100.0 * correct / len(Ciu_host.row))

        X.to_host(self.user_factors)
        Y.to_host(self.item_factors)


@cython.cdivision(True)
@cython.boundscheck(False)
cdef bpr_update(vector[mt19937] & rng, vector[uniform_int_distribution[int]] & dist,
                int[:] userids, int[:] itemids,
                float[:, :] X, float[:, :] Y,
                float learning_rate, float reg, int num_threads):
    cdef int users = X.shape[0], items = Y.shape[0], samples = len(userids)
    cdef int i, j, liked_index, disliked_index, liked_id, disliked_id, thread_id, correct = 0
    cdef float z, score, temp

    cdef float * user
    cdef float * liked
    cdef float * disliked

    cdef int factors = X.shape[1] - 1

    with nogil, parallel(num_threads=num_threads):

        thread_id = get_thread_num()
        for i in prange(samples, schedule='guided'):
            liked_index = dist[thread_id](rng[thread_id])
            disliked_index = dist[thread_id](rng[thread_id])

            liked_id = itemids[liked_index]
            disliked_id = itemids[disliked_index]

            # get pointers to the relevant factors
            user, liked, disliked = &X[userids[liked_index], 0], &Y[liked_id, 0], &Y[disliked_id, 0]

            # compute the score
            score = 0
            for j in range(factors + 1):
                score = score + user[j] * (liked[j] - disliked[j])
            z = 1.0 / (1.0 + exp(score))

            if z < .5:
                correct += 1

            # update the factors via sgd.
            for j in range(factors):
                temp = user[j]
                user[j] += learning_rate * (z * (liked[j] - disliked[j]) - reg * user[j])
                liked[j] += learning_rate * (z * temp - reg * liked[j])
                disliked[j] += learning_rate * (-z * temp - reg * disliked[j])

            # update item bias terms (last column of factorized matrix)
            liked[factors] += learning_rate * (z - reg * liked[factors])
            disliked[factors] += learning_rate * (-z - reg * disliked[factors])

    return correct
